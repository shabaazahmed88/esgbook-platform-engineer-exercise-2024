# ESGBook Platform Engineer Exercise

This repository contains the exercise for the ESGBook Platform Engineer role.

## Time

You can either do this test before the interview or during, we usually recommend doing it before, so we can discuss your
findings during the interview. However, we understand that sometimes it's easier to do it during the interview.

Either way we recommend spending around 1-2 hours on this test if doing it before the interview.

## Requirements

- A way to run a Kubernetes cluster locally, in the example Makefile we use minikube however you can use any other tool
  you prefer.
- Docker to build the images.
- Go if you want to build the services locally.

## Introduction

This exercise is designed to test your ability to deploy and debug services and networking on a Kubernetes cluster.
The example service given is a simple ping/pong service, named PingPong. Which features two main functionalities:

- Pinging: It periodically sends a request to a given target service every n ticks.
- Ponging: It responds with a `pong` message when called on the `GET /ping` endpoint.

There are other functionalities that have been templated out for you to implement, these are optional and are there to
test your ability to think about the wider implications of running a service in production. These are:

- HTTPS
- mTLS
- Prometheus metrics

## Challenges

1) First, you need to write a Dockerfile for the PingPong service. The dockerfile needs to be in the `services/pingpong`
   directory. An example command to build the go binary is:

```
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o pingpong
```

2) Next we'll need to get the cluster up, you should be able to run `make cluster-up-with-services` if you have chosen
   to use minikube.

3) Next lets check if everything is up and running correctly. If not, fix the issues and provide details about your
   findings.

### Optional Challenges

You can pick and choose how you would improve this solution ranging from cluster security all the way to improving the
PingPong service, whatever you choose to do, please document your findings and the steps you took to implement them.

Here are some examples of what you could do, and would encourage you to do:

- Implementing HTTPS
- Implementing mTLS
- Implementing Prometheus metrics
- Better cluster posture, e.g. network policies, pod security policies, etc.
- Service mesh. Zero trust architecture.

### Production Ready

Think about what else you would do to make this service, cluster and solution production ready. Feel free to implement
them or include them in your documentation.

### Submitting

Please send us your solution via email. If you have any questions, please don't hesitate to ask.
