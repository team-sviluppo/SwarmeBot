// What runs on the server during setup — bot-remoto §5.4.
//
// Every script is a fixed text of ours, run as `sh -c '<script>' sh 'a' 'b'`:
// the script on the command line (it is not secret), values as positional
// arguments, single-quoted, and stdin for data only (a key, a binary, the
// sudo password). Never script and data on one stdin: dash reads its input in
// blocks and would run the data as commands. Scripts print `key=value` lines
// (no JSON parser on a bare server) and exit non-zero with a sentence on
// stderr when a step cannot be done. Root steps are shown before they run.
import Foundation

public enum RemoteScripts {
    /// `'it'\''s'`: safe as one shell word, whatever the text.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `sh -c '<script>' sh 'a' 'b'`: inside the script the values are $1, $2….
    public static func command(_ script: String, _ arguments: [String] = []) -> String {
        (["sh", "-c", quote(script), "sh"] + arguments.map(quote)).joined(separator: " ")
    }

    /// Parse `key=value` lines; later keys win, other lines are ignored.
    public static func values(_ output: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    // MARK: Probe (as the user, with the key)

    /// What is on the server and what is missing. Read-only.
    public static let probe = #"""
    set -u
    if [ -r /etc/os-release ]; then . /etc/os-release; echo "os=${ID:-linux}"; echo "version=${VERSION_ID:-}"
    elif command -v sw_vers >/dev/null 2>&1; then echo "os=macos"; echo "version=$(sw_vers -productVersion)"
    else echo "os=$(uname -s)"; fi
    echo "arch=$(uname -m)"
    echo "user=$(id -un)"
    echo "uid=$(id -u)"
    echo "home=$HOME"
    if [ "$(id -u)" = 0 ]; then echo "root=yes"; else echo "root=no"; fi
    if sudo -n true 2>/dev/null; then echo "sudo=nopassword"; elif command -v sudo >/dev/null 2>&1; then echo "sudo=password"; else echo "sudo=none"; fi
    PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    engine="$HOME/.swarmebot/bin/swarme-harness"
    if [ -x "$engine" ]; then
      if command -v sha256sum >/dev/null 2>&1; then echo "engineHash=$(sha256sum "$engine" | cut -d' ' -f1)"
      else echo "engineHash=$(shasum -a 256 "$engine" | cut -d' ' -f1)"; fi
    fi
    # a command that answers no version is not the CLI we mean (macOS has a `pi` of its own on some setups)
    v="$(claude --version 2>/dev/null | head -n1)"; [ -n "$v" ] && echo "claude=$v"
    v="$(pi --version 2>/dev/null | head -n1)"; [ -n "$v" ] && echo "pi=$v"
    command -v node >/dev/null 2>&1 && echo "node=$(node --version 2>/dev/null)"
    command -v caddy >/dev/null 2>&1 && echo "caddy=$(caddy version 2>/dev/null | cut -d' ' -f1)"
    if command -v systemctl >/dev/null 2>&1; then
      echo "service=$(systemctl --user is-active swarmebot.service 2>/dev/null || true)"
      echo "linger=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo unknown)"
    elif command -v launchctl >/dev/null 2>&1; then
      if launchctl print "system/it.swarmebot.engine.$(id -un)" >/dev/null 2>&1; then echo "service=active"; else echo "service=inactive"; fi
    fi
    echo "probe=ok"
    """#

    // MARK: Key (as the user, with the password)

    /// Append the public key (stdin's only line) to authorized_keys, once.
    public static let installKey = #"""
    set -eu
    umask 077
    IFS= read -r key
    case "$key" in ssh-ed25519\ *) ;; *) echo "not an ed25519 public key" >&2; exit 2 ;; esac
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME/.ssh/authorized_keys"
    if grep -qxF "$key" "$HOME/.ssh/authorized_keys"; then echo "key=present"; else printf '%s\n' "$key" >> "$HOME/.ssh/authorized_keys"; echo "key=added"; fi
    """#

    /// Remove our line (`swarmebot:<id>` comment) from authorized_keys. $1 = identity id.
    public static let removeKey = #"""
    set -eu
    file="$HOME/.ssh/authorized_keys"
    [ -f "$file" ] || { echo "key=absent"; exit 0; }
    tmp="$(mktemp "$HOME/.ssh/.ak.XXXXXX")"
    grep -v " swarmebot:$1\$" "$file" > "$tmp" || true
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
    echo "key=removed"
    """#

    // MARK: Engine binary (as the user)

    /// Write stdin (the binary) to ~/.swarmebot/bin/swarme-harness atomically, check its hash. $1 = expected sha256.
    public static let installEngine = #"""
    set -eu
    umask 022
    dir="$HOME/.swarmebot/bin"
    mkdir -p "$dir"
    tmp="$dir/.swarme-harness.$$"
    cat > "$tmp"
    if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$tmp" | cut -d' ' -f1)"; else got="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"; fi
    if [ "$got" != "$1" ]; then rm -f "$tmp"; echo "upload damaged: hash $got, expected $1" >&2; exit 3; fi
    chmod 755 "$tmp"
    mv -f "$tmp" "$dir/swarme-harness"
    echo "engineHash=$got"
    """#

    // MARK: Root setup, Linux (sudo)

    /// Caddy, the socket folder, linger. $1 = user. Idempotent.
    public static let rootLinux = #"""
    set -eu
    user="$1"
    id "$user" >/dev/null 2>&1 || { echo "no such user $user" >&2; exit 2; }
    export DEBIAN_FRONTEND=noninteractive
    # the engine links the system SQLite and libcurl (URLSession); Caddy fronts it
    need=""
    command -v caddy >/dev/null 2>&1 || need="$need caddy"
    dpkg -s libsqlite3-0 >/dev/null 2>&1 || need="$need libsqlite3-0"
    dpkg -s libcurl4t64 >/dev/null 2>&1 || dpkg -s libcurl4 >/dev/null 2>&1 || need="$need libcurl4t64"
    if [ -n "$need" ]; then
      apt-get update -qq
      apt-get install -y -qq $need >/dev/null
    fi
    getent group caddy >/dev/null 2>&1 || { echo "the caddy package did not create a caddy group" >&2; exit 3; }
    # the engine's sockets: reachable by the user and by Caddy, by nobody else
    echo "d /run/swarmebot/$user 2750 $user caddy -" > "/etc/tmpfiles.d/swarmebot-$user.conf"
    systemd-tmpfiles --create "/etc/tmpfiles.d/swarmebot-$user.conf"
    loginctl enable-linger "$user"
    mkdir -p /etc/caddy/swarmebot.d
    echo "socketDir=/run/swarmebot/$user"
    echo "root=ok"
    """#

    /// The user's engine as a systemd user unit. $1 socket dir, $2 public URL.
    public static let serviceLinux = #"""
    set -eu
    unit="$HOME/.config/systemd/user"
    mkdir -p "$unit"
    cat > "$unit/swarmebot.service" <<EOF
    [Unit]
    Description=SwarmeBot remote engine
    After=network-online.target

    [Service]
    Environment=PATH=$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
    ExecStart=$HOME/.swarmebot/bin/swarme-harness serve --remote --socket $1/engine.sock --webhook-socket $1/hooks.sock --public-url $2
    Restart=on-failure
    RestartSec=3

    [Install]
    WantedBy=default.target
    EOF
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    systemctl --user daemon-reload
    systemctl --user enable swarmebot.service >/dev/null 2>&1
    systemctl --user restart swarmebot.service
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
      [ -S "$1/engine.sock" ] && { echo "service=active"; exit 0; }
      sleep 1
    done
    journalctl --user -u swarmebot.service -n 20 --no-pager >&2 || true
    echo "the engine did not open its socket within 30 seconds" >&2
    exit 4
    """#

    /// The user's routes in Caddy, then a validated reload. Root.
    /// $1 user, $2 site (`bot.example.it`, `:8443`…), $3 prefix (`/srv1/deploy`), $4 socket dir, $5 tls (`public`|`internal`|`off`).
    public static let caddyLinux = #"""
    set -eu
    user="$1"; site="$2"; prefix="$3"; sock="$4"; tls="$5"
    conf=/etc/caddy/swarmebot.d
    mkdir -p "$conf"
    routes="$conf/$user.routes"
    [ -f "$routes" ] && cp -p "$routes" "$routes.backup"
    cat > "$routes" <<EOF
    handle_path $prefix/hooks/* {
    	rewrite * /hooks{path}
    	reverse_proxy unix/$sock/hooks.sock
    }
    handle_path $prefix/* {
    	reverse_proxy unix/$sock/engine.sock {
    		flush_interval -1
    		transport http {
    			read_timeout 0
    		}
    	}
    }
    EOF
    case "$tls" in
      internal) tlsline="tls internal" ;;
      off) tlsline="" ; case "$site" in http://*|:*) ;; *) site="http://$site" ;; esac ;;
      *) tlsline="" ;;
    esac
    cat > /etc/caddy/swarmebot.caddy.new <<EOF
    $site {
    	$tlsline
    	import $conf/*.routes
    	handle {
    		respond 404
    	}
    }
    EOF
    main=/etc/caddy/Caddyfile
    touch "$main"
    cp -p "$main" "$main.swarmebot-backup"
    [ -f /etc/caddy/swarmebot.caddy ] && cp -p /etc/caddy/swarmebot.caddy /etc/caddy/swarmebot.caddy.backup
    mv -f /etc/caddy/swarmebot.caddy.new /etc/caddy/swarmebot.caddy
    grep -qxF "import /etc/caddy/swarmebot.caddy" "$main" || printf '\nimport /etc/caddy/swarmebot.caddy\n' >> "$main"
    if ! caddy validate --config "$main" --adapter caddyfile >/tmp/swarmebot-caddy.log 2>&1; then
      cp -p "$main.swarmebot-backup" "$main"
      if [ -f /etc/caddy/swarmebot.caddy.backup ]; then mv -f /etc/caddy/swarmebot.caddy.backup /etc/caddy/swarmebot.caddy; else rm -f /etc/caddy/swarmebot.caddy; fi
      if [ -f "$routes.backup" ]; then mv -f "$routes.backup" "$routes"; else rm -f "$routes"; fi
      tail -n 5 /tmp/swarmebot-caddy.log >&2
      echo "the Caddy configuration was not valid; nothing was changed" >&2
      exit 5
    fi
    systemctl reload caddy || systemctl restart caddy
    echo "caddy=reloaded"
    """#

    // MARK: Mac server (sudo) — bot-remoto §3.5

    /// Everything a Mac server needs, as root, in one idempotent step:
    /// the engine as a LaunchDaemon running as the user (starts at boot, no
    /// login), Caddy as a root LaunchDaemon (it may read the user's 0700
    /// socket folder, so no shared group is needed), the user's routes, a
    /// validated reload. $1 user, $2 site, $3 prefix, $4 tls, $5 public URL.
    public static let rootMac = #"""
    set -eu
    user="$1"; site="$2"; prefix="$3"; tls="$4"; url="$5"
    home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [ -n "$home" ] && [ -d "$home" ] || { echo "no such user $user" >&2; exit 2; }
    engine="$home/.swarmebot/bin/swarme-harness"
    [ -x "$engine" ] || { echo "the engine is not installed in $engine" >&2; exit 2; }
    caddy="$(command -v caddy || true)"
    for c in /opt/homebrew/bin/caddy /usr/local/bin/caddy; do [ -z "$caddy" ] && [ -x "$c" ] && caddy="$c"; done
    [ -n "$caddy" ] || { echo "Caddy is not installed: brew install caddy" >&2; exit 3; }
    sock="$home/.swarmebot/run"
    sudo -u "$user" mkdir -p "$sock" "$home/Library/Logs"
    chmod 700 "$sock"
    label="it.swarmebot.engine.$user"
    plist="/Library/LaunchDaemons/$label.plist"
    cat > "$plist" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>$label</string>
      <key>UserName</key><string>$user</string>
      <key>ProgramArguments</key><array>
        <string>$engine</string><string>serve</string><string>--remote</string>
        <string>--socket</string><string>$sock/engine.sock</string>
        <string>--webhook-socket</string><string>$sock/hooks.sock</string>
        <string>--public-url</string><string>$url</string>
      </array>
      <key>EnvironmentVariables</key><dict>
        <key>HOME</key><string>$home</string>
        <key>PATH</key><string>$home/.local/bin:$home/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
      </dict>
      <key>WorkingDirectory</key><string>$home</string>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>StandardOutPath</key><string>$home/Library/Logs/swarmebot-engine.log</string>
      <key>StandardErrorPath</key><string>$home/Library/Logs/swarmebot-engine.log</string>
    </dict></plist>
    EOF
    chown root:wheel "$plist"; chmod 644 "$plist"
    launchctl bootout "system/$label" 2>/dev/null || true
    launchctl bootstrap system "$plist"

    conf=/usr/local/etc/swarmebot
    mkdir -p "$conf/routes"
    routes="$conf/routes/$user.routes"
    [ -f "$routes" ] && cp -p "$routes" "$routes.backup"
    cat > "$routes" <<EOF
    handle_path $prefix/hooks/* {
    	rewrite * /hooks{path}
    	reverse_proxy unix/$sock/hooks.sock
    }
    handle_path $prefix/* {
    	reverse_proxy unix/$sock/engine.sock {
    		flush_interval -1
    		transport http {
    			read_timeout 0
    		}
    	}
    }
    EOF
    case "$tls" in
      off) case "$site" in http://*|:*) ;; *) site="http://$site" ;; esac ;;
    esac
    cat > "$conf/Caddyfile.new" <<EOF
    {
    	admin off
    }
    $site {
    	import $conf/routes/*.routes
    	handle {
    		respond 404
    	}
    }
    EOF
    if ! "$caddy" validate --config "$conf/Caddyfile.new" --adapter caddyfile >/tmp/swarmebot-caddy.log 2>&1; then
      rm -f "$conf/Caddyfile.new"
      if [ -f "$routes.backup" ]; then mv -f "$routes.backup" "$routes"; else rm -f "$routes"; fi
      tail -n 5 /tmp/swarmebot-caddy.log >&2
      echo "the Caddy configuration was not valid; nothing was changed" >&2
      exit 5
    fi
    mv -f "$conf/Caddyfile.new" "$conf/Caddyfile"
    cplist=/Library/LaunchDaemons/it.swarmebot.caddy.plist
    cat > "$cplist" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>it.swarmebot.caddy</string>
      <key>ProgramArguments</key><array>
        <string>$caddy</string><string>run</string><string>--config</string><string>$conf/Caddyfile</string><string>--adapter</string><string>caddyfile</string>
      </array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>StandardOutPath</key><string>/var/log/swarmebot-caddy.log</string>
      <key>StandardErrorPath</key><string>/var/log/swarmebot-caddy.log</string>
    </dict></plist>
    EOF
    chown root:wheel "$cplist"; chmod 644 "$cplist"
    # admin is off, so a config change is a restart
    launchctl bootout system/it.swarmebot.caddy 2>/dev/null || true
    launchctl bootstrap system "$cplist"
    for i in $(seq 1 30); do
      [ -S "$sock/engine.sock" ] && { echo "socketDir=$sock"; echo "service=active"; echo "root=ok"; exit 0; }
      sleep 1
    done
    tail -n 20 "$home/Library/Logs/swarmebot-engine.log" >&2 || true
    echo "the engine did not open its socket within 30 seconds" >&2
    exit 4
    """#

    // MARK: CLI logins (as the user)

    /// Store Claude's long-lived token (stdin) for the engine, then restart the
    /// engine so the CLIs get it: systemd restarts the unit; on a Mac, launchd
    /// (KeepAlive) starts again the process this ends.
    public static let setClaudeToken = #"""
    set -eu
    "$HOME/.swarmebot/bin/swarme-harness" secret set CLAUDE_CODE_OAUTH_TOKEN >/dev/null
    if command -v systemctl >/dev/null 2>&1; then
      export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      systemctl --user restart swarmebot.service
    else
      pkill -TERM -u "$(id -u)" -f "swarme-harness serve --remote" || true
    fi
    echo "token=set"
    """#

    // MARK: Devices (as the user)

    /// $1 = device name, $2 = kind. Prints the JSON of `device add`.
    public static let addDevice = #"""
    set -eu
    exec "$HOME/.swarmebot/bin/swarme-harness" device add --name "$1" --kind "$2"
    """#
}
