#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  FILE *list = fopen(argv[1], "r");
  if (!list) return 0;
  char path[4096];
  int count = 0;
  long long bytes = 0;
  while (fgets(path, sizeof(path), list)) {
    path[strcspn(path, "\r\n")] = 0;
    int data = !strncmp(path, "/data/openpilot/", 16);
    if ((strcmp(argv[2], "data") == 0) != data) continue;
    if (!data && strncmp(path, "/usr/", 5) && strncmp(path, "/lib/", 5)) continue;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) continue;
    struct stat st;
    if (!fstat(fd, &st) && S_ISREG(st.st_mode)) {
      off_t size = st.st_size < 8*1024*1024 ? st.st_size : 8*1024*1024;
      if (!posix_fadvise(fd, 0, size, POSIX_FADV_WILLNEED)) { ++count; bytes += size; }
    }
    close(fd);
  }
  fclose(list);
  printf("UI readahead %s: %d files, %lld bytes requested\n", argv[2], count, bytes);
  return 0;
}
