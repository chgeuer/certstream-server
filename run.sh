#!/bin/bash

docker stop certstream-container
docker rm certstream-container
docker image rm certstream
docker build -t certstream .
docker run -d -e PORT=4000 -p 4000:4000 --name certstream-container -it certstream

./tail.exs
