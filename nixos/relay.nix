{ ... }:

# A ceiling for remote relay jobs (27 Nov 2026). Every job container is started
# with `docker run --cgroup-parent=relay.slice`, so all of them together stay
# inside these limits whatever relay starts: the owner's rule is that jobs must
# never exhaust this laptop. The devbox VM (4 GiB fixed) and the host itself
# sit outside the slice, and the low weights let the owner's own work win.
{
  systemd.slices.relay = {
    description = "Ceiling for remote relay job containers";
    sliceConfig = {
      CPUQuota      = "400%";  # at most 4 of the 8 cores, all jobs together
      CPUWeight     = 20;      # below the default 100
      MemoryHigh    = "3584M"; # throttled from here
      MemoryMax     = "4G";    # hard ceiling, all jobs together
      MemorySwapMax = "0";
      IOWeight      = 20;
      TasksMax      = 4096;
    };
  };
}
