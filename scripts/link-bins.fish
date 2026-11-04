#!/usr/bin/env fish

set -l repo (realpath (status dirname)/..)
set -l build_dir $repo/zig-out/bin
set -l link_dir $HOME/.local/bin

mkdir -p $link_dir

for name in hen hend
    set -l source $build_dir/$name
    if not test -x $source
        echo "missing executable: $source" >&2
        exit 1
    end
    ln -sf $source $link_dir/$name
    echo "linked $link_dir/$name -> $source"
end

if not contains $link_dir $PATH
    echo "warning: $link_dir is not in PATH"
end
