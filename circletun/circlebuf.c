#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define handle_error(msg) \
    do { perror(msg); exit(EXIT_FAILURE); } while (0)

struct buffer_def {
	char *name;
	int64_t offset;
	int64_t size;
	int fd;
	void *addr;
};

int create_buffer(struct buffer_def *buffer, int read)
{
	int openflags = read ? O_RDONLY : O_RDWR;
	int mapflags = read ? PROT_READ : (PROT_READ | PROT_WRITE);

	buf->fd = open(buffer->name, openflags);
	if (buffer->fd == -1)
	       handle_error("open");
	buffer->addr = mmap(NULL, buffer->size, mapflags, MAP_PRIVATE, buffer->fd, buffer->offset);
	return 0;
}

int close_buffer(struct buffer_def *buffer)
{
	munmap(buffer->addr, buffer->length);
	close(buffer->fd);
}
