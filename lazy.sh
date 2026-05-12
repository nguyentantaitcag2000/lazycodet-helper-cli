#!/bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND_DIR="$BASE_DIR/commands"

COMMAND="$1"

if [ -z "$COMMAND" ]; then
    echo "Usage:"
    echo "  lazy branch.history"
    echo "  lazy update"
    exit 1
fi

COMMAND_FILE="$COMMAND_DIR/$COMMAND.sh"

if [ ! -f "$COMMAND_FILE" ]; then
    echo "Error: Command not found -> $COMMAND"
    exit 1
fi

bash "$COMMAND_FILE"