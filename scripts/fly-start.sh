#!/bin/bash
# Fly start script: run the process matching $FLY_PROCESS_GROUP.
set -e
case "${FLY_PROCESS_GROUP:-app}" in
  app)
    cd /app/relayer
    exec node --import tsx src/server.ts
    ;;
  swap)
    cd /app/swap
    exec node --import tsx src/server.ts
    ;;
  solver)
    cd /app/swap
    exec node --import tsx src/solver.ts
    ;;
  *)
    echo "unknown process group: $FLY_PROCESS_GROUP" >&2
    exit 1
    ;;
esac
