#!/usr/bin/env bash
# scripts/configure_github.sh
# Türkçe: Çoklu proje klasörünü Git ile başlatıp (gerekirse) GitHub'da repo oluşturmaya yardımcı olan güvenli betik.
# Özellikler: --dry-run, --yes, --visibility, --repo-name, --description, --no-folder-name, --branch, --replace-remote, --verbose

set -euo pipefail
IFS=$'\n\t'

PROGNAME="$(basename "$0")"
DRY_RUN=0
ASSUME_YES=0
VISIBILITY="private"
REPO_NAME=""
DESCRIPTION=""
USE_FOLDER_NAME=1
BRANCH="main"
REPLACE_REMOTE=0
VERBOSE=0

print_usage() {
  cat <<EOF
Kullanım: $PROGNAME [options] <project-dir> [project-dir ...]

Options:
  --dry-run             Yapılacakları göster, hiçbir değişiklik yapma
  --yes                 Tüm onayları otomatik "evet" ile geç
  --visibility [public|private]  Oluşturulacak GitHub repo görünürlüğü (default: private)
  --repo-name NAME      Uzaktan repo ismini belirt. Belirtilmezse klasör adı kullanılır.
  --description TEXT    Repo açıklaması
  --no-folder-name      Repo ismi olarak klasör adını kullanma (zorunlu repo-name gerekiyorsa)
  --branch NAME         Default branch ismi (default: main)
  --replace-remote      Eğer remote zaten varsa üzerine yaz
  --verbose             Ayrıntılı çıktı
  -h, --help            Yardım

Örnekler:
  $PROGNAME --dry-run ./projeler/proje1
  $PROGNAME --yes --visibility public --repo-name my-repo ./projeler/*

NOT: Eğer 'gh' (GitHub CLI) kuruluysa betik otomatik repo oluşturur ve push atar. Aksi halde manuel komutları gösterir.
EOF
}

# Basit arg parse (uzun seçenekler)
ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=1; shift;;
    --yes) ASSUME_YES=1; shift;;
    --visibility) VISIBILITY="$2"; shift 2;;
    --repo-name) REPO_NAME="$2"; shift 2;;
    --description) DESCRIPTION="$2"; shift 2;;
    --no-folder-name) USE_FOLDER_NAME=0; shift;;
    --branch) BRANCH="$2"; shift 2;;
    --replace-remote) REPLACE_REMOTE=1; shift;;
    --verbose) VERBOSE=1; shift;;
    -h|--help) print_usage; exit 0;;
    --) shift; while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done; break;;
    -* ) echo "Bilinmeyen seçenek: $1"; print_usage; exit 1;;
    * ) ARGS+=("$1"); shift;;
  esac
done

if [[ ${#ARGS[@]} -eq 0 ]]; then
  # default: current dir
  ARGS+=(".")
fi

# helper
log() { if [[ $VERBOSE -eq 1 ]]; then echo "[INFO] $*"; fi }
run_or_dry() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    echo "+ $*"
    eval "$@"
  fi
}
confirm() {
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  read -r -p "$1 [y/N]: " ans
  case "$ans" in
    [yY]|[yY][eE][sS]) return 0;;
    *) return 1;;
  esac
}

# check prerequisites
if ! command -v git >/dev/null 2>&1; then
  echo "git bulunamadı. Lütfen git kurun ve tekrar deneyin. (ör: sudo apt install git)"
  exit 1
fi
GH_AVAILABLE=0
if command -v gh >/dev/null 2>&1; then
  GH_AVAILABLE=1
  log "gh CLI bulundu"
else
  log "gh CLI bulunamadı - otomatik repo oluşturma devre dışı"
fi

# iterate over projects
SUMMARY=()
for proj in "${ARGS[@]}"; do
  echo "\n=== İşleniyor: $proj ==="
  if [[ ! -e "$proj" ]]; then
    echo "Hata: '$proj' bulunamadı, atlanıyor"
    SUMMARY+=("$proj: NOT FOUND")
    continue
  fi
  # if a file path given, use its dir
  if [[ -f "$proj" ]]; then
    proj_dir=$(dirname "$proj")
  else
    proj_dir="$proj"
  fi
  # absolute path
  proj_dir=$(cd "$proj_dir" >/dev/null 2>&1 && pwd)
  echo "Dizin: $proj_dir"

  pushd "$proj_dir" >/dev/null
  # check if inside git repo
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Bu dizin zaten bir git deposu içinde."
    inside_git=1
  else
    inside_git=0
  fi

  WILL_INIT=0
  if [[ $inside_git -eq 0 ]]; then
    WILL_INIT=1
  fi

  # propose .gitignore
  GITIGNORE_CHOICE="none"
  echo "
Mevcut .gitignore dosyası: $( [[ -f .gitignore ]] && echo 'var' || echo 'yok' )"
  if [[ ! -f .gitignore ]]; then
    echo ".gitignore oluşturmak ister misiniz?"
    if [[ $ASSUME_YES -eq 1 ]]; then
      want_gitignore=1
    else
      read -r -p "Seçim (1: Python, 2: Node, 3: Java, 4: VisualStudio, 5: none) [default 5]: " gi
      gi=${gi:-5}
      if [[ $gi -eq 1 ]]; then GITIGNORE_CHOICE=python; fi
      if [[ $gi -eq 2 ]]; then GITIGNORE_CHOICE=node; fi
      if [[ $gi -eq 3 ]]; then GITIGNORE_CHOICE=java; fi
      if [[ $gi -eq 4 ]]; then GITIGNORE_CHOICE=visualstudio; fi
      if [[ $gi -eq 5 ]]; then GITIGNORE_CHOICE=none; fi
    fi
  else
    GITIGNORE_CHOICE=existing
  fi

  # determine repo name
  if [[ -z "$REPO_NAME" && $USE_FOLDER_NAME -eq 1 ]]; then
    SUGGESTED_NAME=$(basename "$proj_dir")
  else
    SUGGESTED_NAME="$REPO_NAME"
  fi

  echo "Önerilen repo ismi: $SUGGESTED_NAME"
  if [[ -z "$SUGGESTED_NAME" ]]; then
    echo "Repo ismi belirtilmemiş. --repo-name ile bir isim verin veya --no-folder-name seçeneğini kaldırın. Atlanıyor."
    SUMMARY+=("$proj_dir: SKIPPED (no repo name)")
    popd >/dev/null
    continue
  fi

  # detect existing remote
  EXISTING_REMOTE_URL=""
  if git remote get-url origin >/dev/null 2>&1; then
    EXISTING_REMOTE_URL=$(git remote get-url origin)
    echo "Mevcut origin remote: $EXISTING_REMOTE_URL"
  fi

  # Show plan summary for this project
  echo "Plan özeti:"
  [[ $WILL_INIT -eq 1 ]] && echo " - git init yapılacak"
  [[ $GITIGNORE_CHOICE != "none" && $GITIGNORE_CHOICE != "existing" ]] && echo " - .gitignore oluşturulacak (template: $GITIGNORE_CHOICE)"
  if [[ $GH_AVAILABLE -eq 1 ]]; then
    echo " - GitHub CLI ile repo oluşturulacak: $SUGGESTED_NAME (visibility: $VISIBILITY)"
  else
    echo " - gh yok: manuel olarak remote ekleme talimatı gösterilecek"
  fi
  [[ -n "$DESCRIPTION" ]] && echo " - repo açıklaması: $DESCRIPTION"
  echo " - default branch: $BRANCH"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry-run: hiçbir değişiklik yapılmayacak."
    SUMMARY+=("$proj_dir: DRY-RUN OK")
    popd >/dev/null
    continue
  fi

  if ! confirm "Devam edilsin mi?"; then
    echo "Atlanıyor"
    SUMMARY+=("$proj_dir: USER SKIPPED")
    popd >/dev/null
    continue
  fi

  # perform actions
  if [[ $WILL_INIT -eq 1 ]]; then
    run_or_dry "git init"
    run_or_dry "git checkout -b $BRANCH"
  fi

  if [[ "$GITIGNORE_CHOICE" == "python" ]]; then
    cat > .gitignore <<'EOG'
# Python
__pycache__/
*.py[cod]
*.egg-info/
.env
venv/
EOG
    echo ".gitignore (python) oluşturuldu"
  elif [[ "$GITIGNORE_CHOICE" == "node" ]]; then
    cat > .gitignore <<'EOG'
# Node
node_modules/
dist/
.env
EOG
    echo ".gitignore (node) oluşturuldu"
  elif [[ "$GITIGNORE_CHOICE" == "java" ]]; then
    cat > .gitignore <<'EOG'
# Java
target/
*.class
EOG
    echo ".gitignore (java) oluşturuldu"
  elif [[ "$GITIGNORE_CHOICE" == "visualstudio" ]]; then
    cat > .gitignore <<'EOG'
# VisualStudio
.vs/
bin/
obj/
EOG
    echo ".gitignore (visualstudio) oluşturuldu"
  fi

  # stage files if new repo
  run_or_dry "git add -A"
  # commit if there is something to commit
  if git status --porcelain | grep . >/dev/null 2>&1; then
    run_or_dry "git commit -m \"chore: initial commit via configure_github.sh\" || true"
  else
    log "commit atılacak değişiklik yok"
  fi

  # handle remote
  if [[ -n "$EXISTING_REMOTE_URL" && $REPLACE_REMOTE -eq 0 ]]; then
    echo "Remote zaten var ve --replace-remote belirtilmedi; remote değiştirilmeyecek."
    SUMMARY+=("$proj_dir: OK (existing remote)")
    popd >/dev/null
    continue
  fi

  if [[ $GH_AVAILABLE -eq 1 ]]; then
    # gh repo create NAME --private --source=. --remote=origin --push -y
    GH_CMD=(gh repo create "$SUGGESTED_NAME" --$VISIBILITY --source=. --remote=origin --push -y)
    if [[ -n "$DESCRIPTION" ]]; then
      GH_CMD+=(--description "$DESCRIPTION")
    fi
    echo "gh ile repo oluşturuluyor..."
    run_or_dry "${GH_CMD[*]}"
    if [[ $DRY_RUN -eq 0 ]]; then
      echo "Push tamamlandı (origin -> GitHub)"
      SUMMARY+=("$proj_dir: OK (pushed)")
    fi
  else
    # show manual commands
    REMOTE_URL_HINT="git@github.com:YOUR_USERNAME/$SUGGESTED_NAME.git"
    echo "gh CLI yüklü değil; lütfen aşağıdaki komutları çalıştırın (örnek):"
    echo "  git remote add origin $REMOTE_URL_HINT"
    echo "  git push -u origin $BRANCH"
    SUMMARY+=("$proj_dir: MANUAL (showed commands)")
  fi

  popd >/dev/null
done

# summary
echo "\n=== Özet ==="
for s in "${SUMMARY[@]}"; do
  echo "$s"
done

echo "Bitiş. Betiği güvenli modda (dry-run) çalıştırarak önce sonucu kontrol edin."

