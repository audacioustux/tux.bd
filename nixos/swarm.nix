{ config, lib, pkgs, ... }:

let
  cfg = config.tux.swarm;
  stackFile = ../compose/swarm/k8swalski.yml;
in
{
  options.tux.swarm = {
    enable = lib.mkEnableOption "single-node Docker Swarm running the k8swalski stack";
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /persist/k8swalski     0755 root    root    -"
      # k8swalski (image runs as UID 65532) writes its self-signed
      # certs into /tmp. Swarm ignores `tmpfs:`, so bind-mount this.
      "d /persist/k8swalski/tmp 1777 65532 65532 -"
    ];

    # Initialise the swarm once. Idempotent: no-op if already a manager.
    systemd.services.docker-swarm-init = {
      description = "Initialise single-node Docker Swarm";
      wantedBy = [ "multi-user.target" ];
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      path = with pkgs; [ docker iproute2 gawk coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        for _ in $(seq 1 30); do
          docker info >/dev/null 2>&1 && break
          sleep 1
        done

        if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
          addr=$(ip -4 route get 1.1.1.1 \
            | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
          echo "Initialising swarm on $addr"
          docker swarm init --advertise-addr "$addr"
        fi
      '';
    };

    # (Re)deploy the stack whenever the definition changes or the host boots.
    systemd.services.k8swalski-stack = {
      description = "Deploy the k8swalski Docker Swarm stack";
      wantedBy = [ "multi-user.target" ];
      after = [ "docker-swarm-init.service" "network-online.target" ];
      requires = [ "docker-swarm-init.service" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.docker ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "5min";
      };
      script = ''
        docker stack deploy --prune --resolve-image always \
          -c ${stackFile} k8swalski
      '';
    };
  };
}
