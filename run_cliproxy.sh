#!/usr/bin/env bash
# Run any bmc-agent command through the cliproxy backend (glm-5.2 by default).
# Usage:
#   ./run_cliproxy.sh verify --source foo.rs --driver foo --output out/
#   MODEL=glm-4.7 ./run_cliproxy.sh generate --source foo.rs --driver foo
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=cliproxy.env
source ./cliproxy.env
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
echo ">> bmc-agent $*  [provider=cliproxy model=$BMC_AGENT_LLM_MODEL]"
exec uv run bmc-agent "$@"
