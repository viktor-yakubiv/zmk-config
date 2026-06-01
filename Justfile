JUST := just_executable() + " --justfile " + quote(source_file())

# print this message
[default]
@help:
    {{JUST}} --list --unsorted

CONFIG := absolute_path('config')
BUILD  := absolute_path('.build')
OUT    := absolute_path('firmware')
DRAW   := absolute_path('draw')

build_matrix := "build.yaml"

# parse build.yaml and filter targets by expression
_parse_targets $expr="all":
    #!/usr/bin/env bash
    attrs="[.board, .shield, .snippet, .\"artifact-name\", .\"cmake-args\"]"
    filter="(($attrs | map(. // [.]) | combinations), ((.include // {})[] | $attrs)) | join(\",\")"
    echo "$(yq -Poj {{build_matrix}} | jq -r "$filter" | grep -v "^," | grep -i "${expr/#all/.*}")"

# build firmware for single board & shield combination
_build_single $board $shield $snippet $artifact cmake_args *west_args:
    #!/usr/bin/env bash
    set -euo pipefail
    artifact="${artifact:-${shield:+${shield// /+}-}${board//\//_}}"
    build_dir="{{ BUILD / '$artifact' }}"

    echo "Building firmware for $artifact..."
    build=$(cat <<EOF
        west zephyr-export
        west -v build -s zmk/app -d "/workspace/.build/$artifact" -b $board {{ west_args }} ${snippet:+-S "$snippet"} -- \
            -DZMK_CONFIG="/workspace/config" ${shield:+-DSHIELD="$shield"} {{ cmake_args }}
    EOF)
    podman run --rm \
        -v "$(pwd)":/workspace:Z \
        -w /workspace \
        docker.io/zmkfirmware/zmk-build-arm:stable \
        bash -c "$build"

    if [[ -f "$build_dir/zephyr/zmk.uf2" ]]; then
        mkdir -p "{{ OUT }}" && cp "$build_dir/zephyr/zmk.uf2" "{{ OUT }}/$artifact.uf2"
    else
        mkdir -p "{{ OUT }}" && cp "$build_dir/zephyr/zmk.bin" "{{ OUT }}/$artifact.bin"
    fi

# build firmware for matching targets
build expr="all" *west_args:
    #!/usr/bin/env bash
    set -euo pipefail
    targets=$({{JUST}} build_matrix={{build_matrix}} _parse_targets {{ expr }})

    [[ -z $targets ]] && echo "No matching targets found. Aborting..." >&2 && exit 1
    echo "$targets" | while IFS=, read -r board shield snippet artifact cmake_args; do
        {{JUST}} _build_single "$board" "$shield" "$snippet" "$artifact" "$cmake_args" {{ west_args }}
    done

# clear build cache and artifacts
clean:
    rm -rf {{ BUILD }} {{ OUT }}

# clear all automatically generated files
clean-all: clean
    rm -rf .west zmk

# clear nix cache
clean-nix:
    nix-collect-garbage --delete-old

# parse & plot keymap
draw: _check_yq_version
    #!/usr/bin/env bash
    set -euo pipefail
    keymap -c "{{ DRAW }}/config.yaml" parse -z "{{ CONFIG }}/base.keymap" --virtual-layers Combos >"{{ DRAW }}/base.yaml"
    yq -Yi '.combos.[].l = ["Combos"]' "{{ DRAW }}/base.yaml"
    keymap -c "{{ DRAW }}/config.yaml" draw "{{ DRAW }}/base.yaml" -k "ferris/sweep" >"{{ DRAW }}/base.svg"

    jq_expr='
        def extract_label: if type == "string" then . else .t end;
        def is_transparent: type == "object" and (.type == "trans" or .type == "held");
        .layers = {
        Base: [
            [.layers.Base, .layers.Nav, .layers.Fn, .layers.Num, .layers.Sys] | transpose[] |
            (.[0] | if type == "string" then {t: .} else . end) as $base |
            (.[1] | if is_transparent then null else extract_label end) as $nav |
            (.[2] | if is_transparent then null else extract_label end) as $fn |
            (.[3] | if is_transparent then null else extract_label end) as $num |
            (.[4] | if is_transparent then null else extract_label end) as $sys |
            $base
            + (if $nav == null then {} else {tr: $nav} end)
            + (if $fn == null then {} else {tl: $fn} end)
            + (if $num == null then {} else {bl: $num} end)
            + (if $sys == null then {} else {br: $sys} end)
        ],
        Combos: .layers.Combos
        } |
        .combos = [.combos[] | .l = ["Combos"]]
    '
    yq -y "$jq_expr" "{{ DRAW }}/base.yaml" >"{{ DRAW }}/overview.yaml"
    keymap -c "{{ DRAW }}/config.yaml" draw "{{ DRAW }}/overview.yaml" -k "ferris/sweep" >"{{ DRAW }}/overview.svg"
    sed -i '/<text.*class="label"/d' "{{ DRAW }}/overview.svg"

# initialize west
init:
    west init -l config
    west update --fetch-opt=--filter=blob:none
    west zephyr-export

# List build targets. The sed chain removes version and build variants,
# and prints the shield (if given) or otherwise the board name.
list:
    @{{JUST}} build_matrix={{build_matrix}} _parse_targets all \
        | sed 's|[@/][^,]*,|,|' \
        | sed 's|\([^,]*\),\([^,]\+\),.*|\2|' \
        | sed 's|\([^,]*\),,.*|\1|' \
        | sort \
        | column

# update west
update:
    west update --fetch-opt=--filter=blob:none

# upgrade zephyr-sdk and python dependencies
upgrade-sdk:
    nix flake update --flake .

# warn user if they are using golang-yq and not python-yq
[no-exit-message]
_check_yq_version:
    #!/usr/bin/env bash
    if yq --help 2>&1 | grep -qi 'eval'; then
        echo "This script requires python-yq, but PATH contains golang-yq" >&2
        echo "Please install python-yq or use the included nix shell" >&2
        exit 1
    fi

[no-cd]
test $testpath *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    testcase=$(basename "$testpath")
    build_dir="{{ BUILD / "tests" / '$testcase' }}"
    config_dir="{{ '$(pwd)' / '$testpath' }}"
    cd {{ justfile_directory() }}

    if [[ "{{ FLAGS }}" != *"--no-build"* ]]; then
        echo "Running $testcase..."
        rm -rf "$build_dir"
        west build -s zmk/app -d "$build_dir" -b native_sim//zmk_test_mock -- \
            -DCONFIG_ASSERT=y -DZMK_CONFIG="$config_dir"
    fi

    ${build_dir}/zephyr/zmk.exe | sed -e "s/.*> //" |
        tee ${build_dir}/keycode_events.full.log |
        sed -n -f ${config_dir}/events.patterns > ${build_dir}/keycode_events.log
    if [[ "{{ FLAGS }}" == *"--verbose"* ]]; then
        cat ${build_dir}/keycode_events.log
    fi

    if [[ "{{ FLAGS }}" == *"--auto-accept"* ]]; then
        cp ${build_dir}/keycode_events.log ${config_dir}/keycode_events.snapshot
    fi
    diff -auZ ${config_dir}/keycode_events.snapshot ${build_dir}/keycode_events.log
