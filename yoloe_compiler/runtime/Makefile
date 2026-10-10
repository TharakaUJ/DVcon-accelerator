CC = gcc
CFLAGS = -O2 -Wall -Wextra -Wno-unused-parameter -std=c11 -lm

OPS_SRCS = ops/conv.c ops/elementwise.c ops/pool.c ops/concat.c \
           ops/transpose.c ops/split.c ops/slice.c ops/transform.c \
           ops/tile_reduce.c ops/matmul_softmax.c ops/convtranspose.c \
           ops/resize.c ops/topk.c ops/detect_head.c ops/einsum.c

# yoloe_runtime: generic IR runner / verification tool (dumps every tensor)
RUNTIME_SRCS = runtime.c main.c thirdparty/cJSON.c $(OPS_SRCS)
RUNTIME_OBJS = $(RUNTIME_SRCS:.c=.o)

# yoloe_detect: end-to-end object detection (image in, drawn detections out)
DETECT_SRCS = runtime.c detect_main.c image.c postprocess.c thirdparty/cJSON.c $(OPS_SRCS)
DETECT_OBJS = $(DETECT_SRCS:.c=.o)

all: yoloe_runtime yoloe_detect

yoloe_runtime: $(RUNTIME_OBJS)
	$(CC) $(RUNTIME_OBJS) -o yoloe_runtime -lm

yoloe_detect: $(DETECT_OBJS)
	$(CC) $(DETECT_OBJS) -o yoloe_detect -lm

%.o: %.c runtime.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(RUNTIME_OBJS) $(DETECT_OBJS) yoloe_runtime yoloe_detect

.PHONY: all clean
