# Docker Debian (12.5) Image Using XLS Tools

Sample `Dockerfile` demonstrating the download/use of XLS tools/releases in a Debian environment.

```console
$ DOCKER_BUILDKIT=1 docker build -t deb12.5-xlsynth .
```

(Note we use docker buildkit to cut off network access for the `cargo build` process because
we want to ensure the `build.rs` files don't need to pull any additional deps for this build.)