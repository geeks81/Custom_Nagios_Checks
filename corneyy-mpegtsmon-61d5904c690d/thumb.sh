#!/bin/sh

head -c $1 2>&- | ffmpeg -loglevel quiet -i pipe: -f image2  -s 640*480 -c:v mjpeg pipe:

# Extract only I-frames
#head -c $1 2>&- | ffmpeg -loglevel quiet -i pipe: -f image2 -vf '[in]select=eq(pict_type\,I)[out]' -vframes 1 -s 640*480 -c:v mjpeg pipe:

#head -c $1 | ffmpeg -i pipe: -f image2 -vframes 1 -s 640*480 -c:v mjpeg pipe: