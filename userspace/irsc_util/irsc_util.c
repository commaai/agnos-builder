/*
 * irsc_util - IPC Router Security Configuration utility
 *
 * This is a 64-bit replacement for the Qualcomm 32-bit irsc_util binary.
 * It configures the IPC Router security rules and signals IRSC completion
 * to the kernel, which unblocks WiFi and other subsystems.
 *
 * Usage: irsc_util [config_file]
 *   If config_file is provided, it parses security rules from it.
 *   If not provided or file doesn't exist, applies default rules.
 *
 * Config file format (one rule per line):
 *   service_id instance_id group_id [group_id ...]
 *   Use 0xFFFFFFFF for ALL_SERVICE/ALL_INSTANCE
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <linux/types.h>

/* IPC Router definitions from kernel */
#define AF_MSM_IPC          27

#define IPC_ROUTER_IOCTL_MAGIC  0xC3
#define IPC_ROUTER_IOCTL_CONFIG_SEC_RULES \
    _IOR(IPC_ROUTER_IOCTL_MAGIC, 5, struct config_sec_rules_args)

#define ALL_SERVICE         0xFFFFFFFF
#define ALL_INSTANCE        0xFFFFFFFF
#define AID_NET_RAW         3004

struct config_sec_rules_args {
    int num_group_info;
    __u32 service_id;
    __u32 instance_id;
    unsigned int reserved;
    gid_t group_id[0];  /* Variable length array */
};

/* Buffer for config_sec_rules_args + group IDs */
struct sec_rule_buffer {
    struct config_sec_rules_args args;
    gid_t groups[64];  /* Max 64 groups per rule */
};

static int apply_security_rule(int fd, __u32 service_id, __u32 instance_id,
                               gid_t *groups, int num_groups)
{
    struct sec_rule_buffer buf;
    int ret;

    if (num_groups <= 0 || num_groups > 64) {
        fprintf(stderr, "Invalid number of groups: %d\n", num_groups);
        return -1;
    }

    memset(&buf, 0, sizeof(buf));
    buf.args.num_group_info = num_groups;
    buf.args.service_id = service_id;
    buf.args.instance_id = instance_id;
    buf.args.reserved = 0;
    memcpy(buf.groups, groups, num_groups * sizeof(gid_t));

    ret = ioctl(fd, IPC_ROUTER_IOCTL_CONFIG_SEC_RULES, &buf);
    if (ret < 0) {
        fprintf(stderr, "ioctl CONFIG_SEC_RULES failed: %s\n", strerror(errno));
        return -1;
    }

    return 0;
}

static int parse_config_file(int fd, const char *filename)
{
    FILE *fp;
    char line[1024];
    int rules_applied = 0;

    fp = fopen(filename, "r");
    if (!fp) {
        return -1;  /* File doesn't exist or can't be read */
    }

    while (fgets(line, sizeof(line), fp)) {
        __u32 service_id, instance_id;
        gid_t groups[64];
        int num_groups = 0;
        char *token, *saveptr;

        /* Skip comments and empty lines */
        if (line[0] == '#' || line[0] == '\n' || line[0] == '\0')
            continue;

        /* Parse service_id */
        token = strtok_r(line, " \t\n", &saveptr);
        if (!token) continue;
        service_id = strtoul(token, NULL, 0);

        /* Parse instance_id */
        token = strtok_r(NULL, " \t\n", &saveptr);
        if (!token) continue;
        instance_id = strtoul(token, NULL, 0);

        /* Parse group IDs */
        while ((token = strtok_r(NULL, " \t\n", &saveptr)) && num_groups < 64) {
            groups[num_groups++] = (gid_t)strtoul(token, NULL, 0);
        }

        if (num_groups > 0) {
            if (apply_security_rule(fd, service_id, instance_id, groups, num_groups) == 0) {
                rules_applied++;
            }
        }
    }

    fclose(fp);
    return rules_applied;
}

static int apply_default_rules(int fd)
{
    gid_t default_group = AID_NET_RAW;

    printf("Applying default security rules\n");
    return apply_security_rule(fd, ALL_SERVICE, ALL_INSTANCE, &default_group, 1);
}

int main(int argc, char *argv[])
{
    int fd;
    int ret = 0;
    const char *config_file = NULL;

    if (argc > 1) {
        config_file = argv[1];
    }

    /* Open IPC Router socket */
    fd = socket(AF_MSM_IPC, SOCK_DGRAM, 0);
    if (fd < 0) {
        fprintf(stderr, "Failed to open IPC Router socket: %s\n", strerror(errno));
        return 1;
    }

    /* Try to parse config file if provided */
    if (config_file) {
        int rules = parse_config_file(fd, config_file);
        if (rules > 0) {
            printf("Applied %d security rules from %s\n", rules, config_file);
        } else if (rules == 0) {
            printf("No valid rules in %s, applying defaults\n", config_file);
            ret = apply_default_rules(fd);
        } else {
            printf("Config file %s not found, applying defaults\n", config_file);
            ret = apply_default_rules(fd);
        }
    } else {
        ret = apply_default_rules(fd);
    }

    /*
     * Close the socket - this triggers signal_irsc_completion() in the kernel
     * which unblocks subsystems waiting for IRSC configuration.
     */
    close(fd);

    if (ret < 0) {
        fprintf(stderr, "Failed to apply security rules\n");
        return 1;
    }

    printf("IRSC configuration complete\n");
    return 0;
}
