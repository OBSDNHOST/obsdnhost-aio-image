#!/bin/bash
# OBSDNHOST AIO launcher. Lives in the image at /usr/local/bin/obsdnhost-launcher.
# The .obsdnhost folder in the server is only a cache (runtimes, venv, hashes) and is recreated if deleted.
# Uses the image's own Node.js / Python / Java when they match the requested version,
# otherwise downloads the runtime into the server folder.
OBSDNHOST_VERSION=1.2.0

HOME_DIR=${OBSDNHOST_HOME:-/home/container}
cd "$HOME_DIR" || exit 1
D=$HOME_DIR/.obsdnhost
RT=$D/runtimes
SHARED=${SHARED_RUNTIMES:-/mnt/runtimes}
M=$(uname -m)
UA="OBSDNHOST-AIO/$OBSDNHOST_VERSION"
mkdir -p "$D/bin" "$D/tmp" "$D/state" "$RT"
export PATH="$D/bin:$PATH" TMPDIR="$D/tmp"

say()  { printf '\033[1;36m[OBSDNHOST]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[OBSDNHOST] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[OBSDNHOST] %s\033[0m\n' "$*"; exit 1; }
get()  { curl -fsSL --retry 3 -A "$UA" "$@"; }
dl() { # url dest
    say "Downloading $(basename "$2")..."
    curl -fsSL --retry 3 -A "$UA" -o "$2.part" "$1" && mv -f "$2.part" "$2" && return
    rm -f "$2.part"; die "Download failed: $1"
}
md5() { md5sum | cut -d' ' -f1; }

need_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    local a=amd64; [ "$M" = aarch64 ] && a=arm64
    dl "https://github.com/jqlang/jq/releases/latest/download/jq-linux-$a" "$D/bin/jq"
    chmod +x "$D/bin/jq"
}

# ---------------------------------------------------------------- git
git_sync() {
    [ -z "$GIT_REPO" ] && return 0
    command -v git >/dev/null 2>&1 || die "git is not available in this image."
    local url=$GIT_REPO auth=() branch=$GIT_BRANCH
    [[ "$url" == *://* || "$url" == git@* ]] || url="https://$url"
    [ -n "$GIT_PAT" ] && auth=(-c "http.extraHeader=Authorization: Basic $(printf 'oauth2:%s' "$GIT_PAT" | base64 -w0)")
    if [ ! -d .git ]; then
        say "Cloning $GIT_REPO..."
        git init -q && git remote add origin "$url"
        if [ -z "$branch" ]; then
            branch=$(git "${auth[@]}" ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2}')
        fi
        git "${auth[@]}" fetch -q origin "${branch:-main}" && git checkout -q -f -B "${branch:-main}" FETCH_HEAD \
            || { rm -rf .git; die "Could not clone $GIT_REPO (check URL, branch and access token)."; }
        git branch -q --set-upstream-to="origin/${branch:-main}" 2>/dev/null
        printf '.obsdnhost/\n' >> .git/info/exclude
    elif [ "${AUTO_UPDATE:-1}" = 1 ]; then
        say "Pulling latest changes..."
        git remote set-url origin "$url"
        git "${auth[@]}" pull -q --ff-only origin "${branch:-$(git rev-parse --abbrev-ref HEAD)}" \
            || warn "git pull failed; starting with the current files."
    fi
}

# ---------------------------------------------------------------- runtimes
ensure_node() {
    local want=${NODE_VERSION#v} sys ver idx dir d a=x64
    [ "$M" = aarch64 ] && a=arm64
    if command -v node >/dev/null 2>&1; then
        sys=$(node -v); sys=${sys#v}
        if [ -z "$want" ] || [[ "$sys" == "$want" || "$sys" == "$want".* ]]; then
            say "Using Node.js $sys"; return 0
        fi
    fi
    if need_jq && idx=$(get https://nodejs.org/dist/index.json); then
        if [ -z "$want" ]; then
            ver=$(jq -r '[.[] | select(.lts)][0].version' <<< "$idx")
        else
            ver=$(jq -r --arg w "v$want" '[.[] | select(.version == $w or (.version | startswith($w + ".")))][0].version // empty' <<< "$idx")
        fi
    else # offline: reuse a cached matching version
        ver=$(ls -d "$SHARED"/node-v"$want"* "$RT"/node-v"$want"* 2>/dev/null | sed 's#.*/node-##' | sort -V | tail -1)
    fi
    [ -z "$ver" ] && die "Node.js version '${want:-LTS}' not found."
    for d in "$SHARED/node-$ver" "$RT/node-$ver"; do
        [ -x "$d/bin/node" ] && { export PATH="$d/bin:$PATH"; say "Using Node.js $ver"; return 0; }
    done
    dir=$RT/node-$ver
    dl "https://nodejs.org/dist/$ver/node-$ver-linux-$a.tar.gz" "$D/tmp/node.tgz"
    rm -rf "$dir"; mkdir -p "$dir"
    tar -xzf "$D/tmp/node.tgz" -C "$dir" --strip-components=1 || die "Could not extract Node.js $ver."
    rm -f "$D/tmp/node.tgz"
    find "$RT" -maxdepth 1 -name 'node-*' ! -name "node-$ver" -exec rm -rf {} +
    export PATH="$dir/bin:$PATH"; say "Using Node.js $ver"
}

ensure_uv() {
    export UV_PYTHON_INSTALL_DIR=$RT/python UV_CACHE_DIR=$D/cache/uv UV_PYTHON_PREFERENCE=only-managed UV_NO_PROGRESS=1
    [ -x "$D/bin/uv" ] && return 0
    local a=x86_64; [ "$M" = aarch64 ] && a=aarch64
    dl "https://github.com/astral-sh/uv/releases/latest/download/uv-$a-unknown-linux-gnu.tar.gz" "$D/tmp/uv.tgz"
    tar -xzf "$D/tmp/uv.tgz" -C "$D/bin" --strip-components=1 || die "Could not extract uv."
    rm -f "$D/tmp/uv.tgz"
}

ensure_python() {
    local py=$PYTHON_VERSION venv=$D/venv id
    if [ -z "$py" ] && command -v python3 >/dev/null 2>&1 && python3 -c 'import venv, ensurepip' 2>/dev/null; then
        id="system-$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
        if [ ! -x "$venv/bin/python" ] || [ "$(cat "$venv/.obsdnhost-python" 2>/dev/null)" != "$id" ]; then
            say "Creating Python virtualenv ($id)..."
            rm -rf "$venv"; python3 -m venv "$venv" || die "Could not create a Python virtualenv."
            echo "$id" > "$venv/.obsdnhost-python"
        fi
    else
        py=${py:-3.13}; ensure_uv
        if [ ! -x "$venv/bin/python" ] || [ "$(cat "$venv/.obsdnhost-python" 2>/dev/null)" != "$py" ]; then
            say "Setting up Python $py..."
            rm -rf "$venv"; uv venv -q --seed --python "$py" "$venv" || die "Could not install Python $py."
            echo "$py" > "$venv/.obsdnhost-python"
        fi
    fi
    export VIRTUAL_ENV=$venv PATH="$venv/bin:$PATH" PYTHONUNBUFFERED=1
    say "Using $(python --version 2>&1)"
}

ensure_java() {
    local want=${JAVA_VERSION//[^0-9]/} sys dir d a=x64
    [ "$M" = aarch64 ] && a=aarch64
    if command -v java >/dev/null 2>&1; then
        sys=$(java -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)
        if [ -z "$want" ] || [ "$sys" = "$want" ]; then say "Using system Java $sys"; return 0; fi
    fi
    want=${want:-21}
    for d in "$SHARED/java-$want" "$RT/java-$want"; do
        [ -x "$d/bin/java" ] && { export JAVA_HOME=$d PATH="$d/bin:$PATH"; say "Using Java $want"; return 0; }
    done
    dir=$RT/java-$want
    dl "https://api.adoptium.net/v3/binary/latest/$want/ga/linux/$a/jre/hotspot/normal/eclipse" "$D/tmp/java.tgz"
    rm -rf "$dir"; mkdir -p "$dir"
    tar -xzf "$D/tmp/java.tgz" -C "$dir" --strip-components=1 || die "Could not extract Java $want."
    rm -f "$D/tmp/java.tgz"
    find "$RT" -maxdepth 1 -name 'java-*' ! -name "java-$want" -exec rm -rf {} +
    export JAVA_HOME=$dir PATH="$dir/bin:$PATH"; say "Using Java $want"
}

jvm_flags() {
    local extra reserve mem=${SERVER_MEMORY:-0}; read -ra extra <<< "$JAVA_ARGUMENTS"
    JFLAGS=(-Xms128M)
    if [[ "$JAVA_ARGUMENTS" != *-Xmx* && "$JAVA_ARGUMENTS" != *MaxRAM* ]] && [ "$mem" -gt 0 ] 2>/dev/null; then
        reserve=$((mem / 10)); [ "$reserve" -lt 128 ] && reserve=128; [ "$reserve" -gt 1024 ] && reserve=1024
        JFLAGS+=("-Xmx$((mem - reserve))M")
    fi
    JFLAGS+=("${extra[@]}")
}

# Which runtimes does this server need? RUNTIMES = auto, or a list like "nodejs,python,java"
want_rt() {
    local r=${RUNTIMES:-auto} cmds="$ADDITIONAL_COMMAND $CUSTOM_COMMAND"
    case ",$r," in *,"$1",*) return 0;; esac
    [ "$r" = auto ] || return 1
    case $1 in
        nodejs) [ -f package.json ] || [ -n "$NODE_PACKAGES" ] || [[ "$STARTUP_FILE" =~ \.(js|mjs|cjs|ts)$ ]] \
                    || [[ "$cmds" =~ (^|[[:space:];\&])(node|npm|npx|tsx)([[:space:]]|$) ]] ;;
        python) [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -n "$PIP_PACKAGES" ] || compgen -G './*.py' >/dev/null \
                    || [[ "$STARTUP_FILE" == *.py ]] || [[ "$cmds" =~ (^|[[:space:];\&])(python3?|pip3?)([[:space:]]|$) ]] ;;
        java)   compgen -G './*.jar' >/dev/null || [[ "$STARTUP_FILE" == *.jar ]] \
                    || [[ "$cmds" =~ (^|[[:space:];\&])java([[:space:]]|$) ]] ;;
    esac
}

# ---------------------------------------------------------------- dependencies (only when inputs change)
node_deps() {
    [ -f package.json ] || [ -n "$NODE_PACKAGES" ] || return 0
    export NPM_CONFIG_UPDATE_NOTIFIER=false
    local h; h=$({ cat package.json package-lock.json 2>/dev/null; echo "$NODE_PACKAGES"; node -v; } | md5)
    if [ "$h" != "$(cat "$D/state/node.hash" 2>/dev/null)" ] || { [ -f package.json ] && [ ! -d node_modules ]; }; then
        if [ -f package.json ]; then
            say "Installing npm dependencies..."
            npm install --no-audit --no-fund --loglevel=error || { warn "npm install failed."; return 0; }
        fi
        if [ -n "$NODE_PACKAGES" ]; then
            # shellcheck disable=SC2086
            say "Installing extra npm packages: $NODE_PACKAGES"; npm install --no-save --no-audit --no-fund --loglevel=error $NODE_PACKAGES || { warn "Extra npm packages failed."; return 0; }
        fi
        echo "$h" > "$D/state/node.hash"
    fi
}

pipi() { if [ -x "$D/bin/uv" ]; then uv pip install -q "$@"; else pip install -q --disable-pip-version-check "$@"; fi; }

python_deps() {
    [ -f requirements.txt ] || [ -n "$PIP_PACKAGES" ] || return 0
    local h; h=$({ cat requirements.txt 2>/dev/null; echo "$PIP_PACKAGES"; python --version 2>&1; } | md5)
    if [ "$h" != "$(cat "$D/state/py.hash" 2>/dev/null)" ]; then
        if [ -f requirements.txt ]; then
            say "Installing requirements.txt..."; pipi -r requirements.txt || { warn "requirements.txt install failed."; return 0; }
        fi
        if [ -n "$PIP_PACKAGES" ]; then
            # shellcheck disable=SC2086
            say "Installing extra pip packages: $PIP_PACKAGES"; pipi $PIP_PACKAGES || { warn "Extra pip packages failed."; return 0; }
        fi
        echo "$h" > "$D/state/py.hash"
    fi
}

# ---------------------------------------------------------------- user-space tools (no root needed)
# Tools installed by System Packages live in .obsdnhost/root; npm -g installs live in .obsdnhost/npm-global.
export_tool_paths() {
    local arch=x86_64-linux-gnu; [ "$M" = aarch64 ] && arch=aarch64-linux-gnu
    export NPM_CONFIG_PREFIX=$D/npm-global
    export PATH="$PATH:$D/npm-global/bin:$D/root/usr/bin:$D/root/bin:$D/root/usr/sbin"
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$D/root/usr/lib/$arch:$D/root/lib/$arch:$D/root/usr/lib"
}

# Downloads the requested Debian/Ubuntu packages (plus any dependencies the image lacks)
# and unpacks them into .obsdnhost/root. Works as a normal user: apt only downloads.
sys_packages() {
    [ -n "$SYSTEM_PACKAGES" ] || return 0
    local h p deb A=$D/apt R=$D/root
    h=$(echo "$SYSTEM_PACKAGES" | md5)
    [ "$h" = "$(cat "$D/state/sys.hash" 2>/dev/null)" ] && return 0
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-deb >/dev/null 2>&1; then
        warn "System Packages needs a Debian/Ubuntu based image (apt-get and dpkg-deb)."; return 0
    fi
    for p in $SYSTEM_PACKAGES; do
        [[ "$p" =~ ^[a-z0-9][a-z0-9.+:-]*$ ]] || { warn "Invalid package name '$p' - skipping System Packages."; return 0; }
    done
    rm -rf "$A"; mkdir -p "$A/lists/partial" "$A/archives/partial" "$A/cache" "$R"
    cp /var/lib/dpkg/status "$A/status" 2>/dev/null || : > "$A/status"
    local o=(-o Dir::State="$A" -o Dir::State::lists="$A/lists" -o Dir::State::status="$A/status"
             -o Dir::Cache="$A/cache" -o Dir::Cache::archives="$A/archives" -o Debug::NoLocking=1 -o APT::Sandbox::User=)
    say "Installing system packages: $SYSTEM_PACKAGES"
    apt-get "${o[@]}" -qq update || { warn "apt update failed; system packages not installed."; rm -rf "$A"; return 0; }
    # shellcheck disable=SC2086
    apt-get "${o[@]}" -y -qq --no-install-recommends --download-only install $SYSTEM_PACKAGES \
        || { warn "Could not download: $SYSTEM_PACKAGES (check the package names)."; rm -rf "$A"; return 0; }
    for deb in "$A"/archives/*.deb; do [ -f "$deb" ] && dpkg-deb -x "$deb" "$R"; done
    rm -rf "$A"
    echo "$h" > "$D/state/sys.hash"
    say "System packages installed."
}

# ---------------------------------------------------------------- what to run
pick_file() { local f; for f in "$@"; do [ -n "$f" ] && [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }

pick_main() {
    MAIN=()
    if [ -n "$CUSTOM_COMMAND" ]; then MAIN=(bash -c "$CUSTOM_COMMAND"); return; fi
    local f=$STARTUP_FILE jars
    if [ -n "$f" ]; then
        [ -f "$f" ] || die "Startup File '$f' not found."
    else
        if [ -f package.json ] && command -v node >/dev/null 2>&1 && [ -n "$(node -p "require('./package.json').scripts?.start || ''" 2>/dev/null)" ]; then
            MAIN=(npm start); return
        fi
        f=$(pick_file index.js main.js bot.js app.js index.mjs main.py bot.py app.py index.py run.py)
        if [ -z "$f" ]; then
            jars=(./*.jar)
            [ -f "${jars[0]}" ] && [ ${#jars[@]} -eq 1 ] && f=${jars[0]#./}
        fi
        [ -z "$f" ] && die "Nothing to run. Upload your bot (or set a Git Repository), then set Startup File or Custom Command in the Startup tab."
    fi
    case $f in
        *.js|*.mjs|*.cjs) MAIN=(node "$f") ;;
        *.ts)             MAIN=(npx --yes tsx "$f") ;;
        *.py)             MAIN=(python -u "$f") ;;
        *.jar)            jvm_flags; MAIN=(java "${JFLAGS[@]}" -jar "$f") ;;
        *.sh)             MAIN=(bash "$f") ;;
        *)                chmod +x "$f" 2>/dev/null; MAIN=("./$f") ;;
    esac
}

# ---------------------------------------------------------------- main
command -v curl >/dev/null 2>&1 || die "curl is missing from this image."
git_sync
export_tool_paths
sys_packages

want_rt nodejs && { ensure_node; node_deps; }
want_rt python && { ensure_python; python_deps; }
want_rt java   && ensure_java

if [ -n "$PRE_START_COMMAND" ]; then
    say "Running pre-start command..."
    bash -c "$PRE_START_COMMAND" || warn "Pre-start command exited with an error."
fi

pick_main
say "Starting: ${MAIN[*]}"
echo "[OBSDNHOST] Started"

if [ -z "$ADDITIONAL_COMMAND" ]; then
    exec "${MAIN[@]}"
fi

# Two processes: run both, forward the stop signal, exit when the main one exits.
say "Starting additional process: $ADDITIONAL_COMMAND"
bash -c "$ADDITIONAL_COMMAND" &
add=$!
"${MAIN[@]}" <&0 &
main=$!
trap 'kill -TERM "$main" "$add" 2>/dev/null' INT TERM
wait "$main"; rc=$?
while kill -0 "$main" 2>/dev/null; do wait "$main"; rc=$?; done
kill -TERM "$add" 2>/dev/null; wait "$add" 2>/dev/null
exit "$rc"
