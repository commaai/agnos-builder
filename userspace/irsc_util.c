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

#ifndef PF_MSM_IPC
#define PF_MSM_IPC AF_MSM_IPC
#endif

struct config_sec_rules_args {
  int num_group_info;
  uint32_t service_id;
  uint32_t instance_id;
  unsigned int reserved;
  gid_t group_id[0];
};

#define ALL_SERVICE 0xFFFFFFFFU
#define ALL_INSTANCE 0xFFFFFFFFU
#define AID_NET_RAW 3004
#define IPC_ROUTER_IOCTL_MAGIC 0xC3
#define IPC_ROUTER_IOCTL_CONFIG_SEC_RULES \
  _IOR(IPC_ROUTER_IOCTL_MAGIC, 5, struct config_sec_rules_args)

int main(int argc, char **argv) {
  (void)argc;
  (void)argv;

  int fd = socket(AF_MSM_IPC, SOCK_DGRAM, 0);
  if (fd < 0) {
    fprintf(stderr, "irsc_util: socket(AF_MSM_IPC) failed: %s\n", strerror(errno));
    return 1;
  }

  struct {
    struct config_sec_rules_args args;
    gid_t group_id;
  } rule = {
    .args = {
      .num_group_info = 1,
      .service_id = ALL_SERVICE,
      .instance_id = ALL_INSTANCE,
    },
    .group_id = AID_NET_RAW,
  };

  int ret = ioctl(fd, IPC_ROUTER_IOCTL_CONFIG_SEC_RULES, &rule);
  if (ret < 0) {
    fprintf(stderr, "irsc_util: IPC router rejected security config: %s\n", strerror(errno));
    close(fd);
    return 1;
  }

  close(fd);
  return 0;
}
