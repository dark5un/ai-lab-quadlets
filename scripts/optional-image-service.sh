#!/usr/bin/env bash
# Start an optional quadlet only when its required local image is available.
# restart_service is provided by the caller to preserve deployment ordering.
start_optional_image_service() {
    local service="$1"
    local image="$2"

    if podman image exists "$image" 2>/dev/null; then
        restart_service "$service"
    else
        echo "  ~ ${service} skipped: required image ${image} is unavailable"
        systemctl --user disable --now "${service}.service" 2>/dev/null || true
    fi
}
