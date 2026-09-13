build:
    just --justfile libs/core/justfile --working-directory libs/core build
    just --justfile apps/cli/justfile --working-directory apps/cli build

test:
    just --justfile libs/core/justfile --working-directory libs/core test
    just --justfile apps/cli/justfile --working-directory apps/cli test

fmt:
    just --justfile libs/core/justfile --working-directory libs/core fmt
    just --justfile apps/cli/justfile --working-directory apps/cli fmt

dev-build:
    just --justfile apps/cli/justfile --working-directory apps/cli build

dev-link:
    mkdir -p ~/.local/bin
    ln -sf "{{justfile_directory()}}/apps/cli/zig-out/bin/tiqet" ~/.local/bin/tiqet-dev

dogfood: dev-build dev-link
