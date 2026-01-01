#!/usr/bin/env bash
# ftrace-setup.sh
# Prepare function_graph tracer and permissions for user 'rbac'.
# Safe to run multiple times. Requires root.
set -euo pipefail

TRACE_DIR="/sys/kernel/tracing"
RBAC_USER="${RBAC_USER:-rbac}"
RBAC_GROUP="${RBAC_GROUP:-rbac}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require id
require grep
require sed
require chown
require chmod

if ! id "$RBAC_USER" >/dev/null 2>&1; then
  echo "Creating user/group '$RBAC_USER'..."
  groupadd -f "$RBAC_GROUP"
  id "$RBAC_USER" >/dev/null 2>&1 || useradd -g "$RBAC_GROUP" -M -s /usr/sbin/nologin "$RBAC_USER"
fi

if [ ! -d "$TRACE_DIR" ]; then
  echo "tracefs not mounted at $TRACE_DIR; attempting mount..."
  mount -t tracefs nodev "$TRACE_DIR" || {
    echo "ERROR: cannot mount tracefs at $TRACE_DIR" >&2
    exit 1
  }
fi

echo 0 > "$TRACE_DIR/tracing_on" || true

# Select function_graph tracer if available
if grep -q function_graph "$TRACE_DIR/available_tracers"; then
  echo function_graph > "$TRACE_DIR/current_tracer"
else
  echo "WARNING: function_graph tracer not available; falling back to function" >&2
  echo function > "$TRACE_DIR/current_tracer"
fi

# Reasonable buffer and options
# (Adjust if you see overruns on busy systems)
echo 4096 > "$TRACE_DIR/buffer_size_kb" || true

# Quiet the output to make parsing simpler
for opt in funcgraph-irqs \
           funcgraph-tail \
           funcgraph-proc \
           funcgraph-duration \
           funcgraph-abstime \
           irq-info; do
  if [ -f "$TRACE_DIR/trace_options" ]; then
    # Disable all by default, then enable duration/proc
    echo "no${opt}" > "$TRACE_DIR/trace_options" 2>/dev/null || true
  fi
done

# We keep duration and proc context on (useful for graph features)
for opt in funcgraph-duration funcgraph-proc; do
  echo "${opt}" > "$TRACE_DIR/trace_options" 2>/dev/null || true
done

# Clear old data
: > "$TRACE_DIR/trace" || true

# Set permissions so the rbac user can read live trace_pipe safely
# (trace_pipe is non-seekable; reading is streaming)
chown root:"$RBAC_GROUP" "$TRACE_DIR/trace_pipe" || true
chmod 0640 "$TRACE_DIR/trace_pipe" || true

# Allow reading static snapshot too (optional)
chown root:"$RBAC_GROUP" "$TRACE_DIR/trace" || true
chmod 0640 "$TRACE_DIR/trace" || true

# You can optionally filter symbols here (uncomment and tailor):
# echo 0 > "$TRACE_DIR/tracing_on"
# echo > "$TRACE_DIR/set_graph_function"
# while read -r sym; do
#   echo "$sym" >> "$TRACE_DIR/set_graph_function"
# done < /opt/rbac-poc/artefacts/ftrace_keys.txt
# echo 1 > "$TRACE_DIR/tracing_on"

echo 1 > "$TRACE_DIR/tracing_on" || true

echo "ftrace setup complete. current_tracer=$(cat $TRACE_DIR/current_tracer)"
echo "trace_pipe readable by group '$RBAC_GROUP'."
