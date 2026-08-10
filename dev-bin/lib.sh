#!/usr/bin/env bash
#
# Helpers shared by the scripts in this directory. Source it, do not run it:
#
#     . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#
# The submodule's dev-bin/gate-extension.sh carries its own copy of fail(). It
# is not sourced from here on purpose: it runs from a checkout of a different
# repository, and both repositories run it, so it has to stand alone.

# ::error:: promotes the message to a GitHub annotation, which is the
# difference between a diagnosis on the run summary and one line somewhere in a
# job log. Exits, so callers can use it as the right-hand side of `||`.
fail() {
    echo "::error::$*"
    exit 1
}
