# Runs Maybe natively, without Docker: `devenv up` starts Postgres, Redis, the
# web server and Sidekiq in production mode, like compose.yml does.
#
# Docker keeps working alongside this; the two stacks have separate databases
# and storage, and both serve on 3088, so run one at a time. Ports are moved off
# the defaults so they do not clash with other projects' services:
#
#   web 3088   postgres 5582   redis 6529
#
# Production mode caches classes and serves precompiled assets, so a code
# change needs `devenv processes restart web worker` (assets are rebuilt when
# web starts). Secrets (SECRET_KEY_BASE etc.) come from .env, read at runtime.
{ pkgs, lib, ... }:

let
  # ruby-vips dlopens libvips at runtime, so it needs a search path. macOS
  # strips DYLD_* variables whenever a process goes through a system binary,
  # and bin/rails, bundle and sidekiq all start with `#!/usr/bin/env ruby`; so
  # the variable is exported in a Nix shell and Ruby is started directly.
  exportVipsPath = ''
    export DYLD_FALLBACK_LIBRARY_PATH="${lib.makeLibraryPath [ pkgs.vips pkgs.glib ]}"
  '';

  # .env holds SECRET_KEY_BASE and the rest. Docker gets it from compose;
  # dotenv-rails is not loaded in production, and devenv's own `dotenv` option
  # would copy the secrets into the world-readable Nix store. So it is read at
  # runtime, the way compose reads it: KEY=value per line, surrounding quotes
  # stripped, no shell expansion (BACKUP_HOST_ROOT has an unquoted space), and
  # anything already set in the environment wins.
  loadDotenv = ''
    if [ -f "$DEVENV_ROOT/.env" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ""|"#"*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key=''${line%%=*}
        value=''${line#*=}
        case "$value" in
          \"*\") value=''${value#\"}; value=''${value%\"} ;;
          \'*\') value=''${value#\'}; value=''${value%\'} ;;
        esac
        [ -n "''${!key+set}" ] || export "$key=$value"
      done < "$DEVENV_ROOT/.env"
      unset line key value
    fi
  '';

  # Gemfile.lock pins Bundler (BUNDLED WITH). When the running Bundler differs,
  # Bundler installs the pinned one and re-executes the command through its
  # `#!/usr/bin/env ruby` shebang, which drops DYLD_* again. Asking RubyGems for
  # the pinned version up front avoids the re-exec, and leaves Gemfile.lock alone.
  lockLines = lib.splitString "\n" (builtins.readFile ./Gemfile.lock);
  bundledWith = lib.trim (lib.elemAt lockLines (lib.lists.findFirstIndex (l: l == "BUNDLED WITH") null lockLines + 1));

  ensureBundler = ''
    gem list -i bundler -v "$BUNDLER_VERSION" >/dev/null 2>&1 \
      || gem install --no-document bundler -v "$BUNDLER_VERSION" >/dev/null
  '';

  # The cluster belongs to the OS user, who connects with trust auth. Named
  # explicitly so database.yml carries a user, as it does under Docker.
  exportDbUser = ''
    export POSTGRES_USER="''${POSTGRES_USER:-$(id -un)}"
  '';

  runtime = ensureBundler + loadDotenv + exportDbUser + exportVipsPath;
in
{
  packages = with pkgs; [
    libpq       # pg gem
    libyaml     # psych gem
    vips        # ruby-vips (ActiveStorage variants)
    pkg-config
  ];

  env = {
    RAILS_ENV = "production";
    SELF_HOSTED = "true";
    RAILS_FORCE_SSL = "false";
    RAILS_ASSUME_SSL = "false";

    DB_HOST = "127.0.0.1";
    DB_PORT = "5582";
    REDIS_URL = "redis://127.0.0.1:6529/1";

    # libpq tries GSS encryption on every TCP connection by default.
    PGGSSENCMODE = "disable";

    # The pg gem builds against pg_config, which nixpkgs ships as its own
    # output; named explicitly so a version manager's shim cannot shadow it.
    BUNDLE_BUILD__PG = "--with-pg-config=${pkgs.libpq.pg_config}/bin/pg_config";

    BUNDLER_VERSION = bundledWith;
  };

  enterShell = runtime;

  languages.ruby = {
    enable = true;
    versionFile = ./.ruby-version;
    # solargraph fails to build on this nixpkgs, and the app does not need it.
    lsp.enable = false;
  };

  # Trust auth on 127.0.0.1; the role is the OS user (see exportDbUser). A
  # POSTGRES_PASSWORD in .env is Docker's and ignored here.
  services.postgres = {
    enable = true;
    package = pkgs.postgresql_16;
    listen_addresses = "127.0.0.1";
    port = 5582;
  };

  services.redis = {
    enable = true;
    port = 6529;
  };

  # MAYBE_PORT overrides the web port for one run, e.g. while Docker still
  # holds 3088: `MAYBE_PORT=3089 devenv up`.
  processes = {
    web.exec = runtime + ''
      until pg_isready -q -h 127.0.0.1 -p 5582; do sleep 1; done
      ruby bin/rails db:prepare
      ruby bin/rails assets:precompile
      exec ruby bin/rails server -b 127.0.0.1 -p "''${MAYBE_PORT:-3088}"
    '';
    worker.exec = runtime + ''
      exec ruby -S bundle exec sidekiq
    '';
  };
}
