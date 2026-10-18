#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef AF_MSM_IPC
#define AF_MSM_IPC 27
#endif

struct config_sec_rules_args {
  int num_group_info;
  uint32_t service_id;
  uint32_t instance_id;
  unsigned int reserved;
};

#define IPC_ROUTER_IOCTL_MAGIC 0xC3
#define IPC_ROUTER_IOCTL_CONFIG_SEC_RULES \
  _IOR(IPC_ROUTER_IOCTL_MAGIC, 5, struct config_sec_rules_args)

int main(int argc, char **argv) {
  if (argc > 1 && access(argv[1], F_OK) == 0) {
    fprintf(stderr, "irsc_util: custom security config is not supported: %s\n", argv[1]);
    return 1;
  }

  int fd = socket(AF_MSM_IPC, SOCK_DGRAM, 0);
  if (fd < 0) {
    fprintf(stderr, "irsc_util: socket(AF_MSM_IPC) failed: %s\n", strerror(errno));
    return 1;
  }

  // Match the vendor utility's absent-config path: leave existing rules alone.
  // The kernel returns EINVAL but marks this as an IRSC socket; closing it
  // signals configuration completion and unblocks IPC clients.
  struct config_sec_rules_args rule = {0};

  int ret = ioctl(fd, IPC_ROUTER_IOCTL_CONFIG_SEC_RULES, &rule);
  if (ret < 0 && errno != EINVAL) {
    fprintf(stderr, "irsc_util: IPC router rejected security config: %s\n", strerror(errno));
    close(fd);
    return 1;
  }

  close(fd);
  return 0;
}
