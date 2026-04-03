package main

import (
	"context"
	"dagger/yoke/internal/dagger"
)

type Yoke struct{}

func (m *Yoke) withCaches(container *dagger.Container, targetSuffix string) *dagger.Container {
	registryCache := dag.CacheVolume("dagger-cargo-registry-" + targetSuffix)
	gitCache := dag.CacheVolume("dagger-cargo-git-" + targetSuffix)
	targetCache := dag.CacheVolume("dagger-cargo-target-" + targetSuffix)

	return container.
		WithMountedCache("/root/.cargo/registry", registryCache).
		WithMountedCache("/root/.cargo/git", gitCache).
		WithMountedCache("/app/target", targetCache)
}

func (m *Yoke) Upload(
	ctx context.Context,
	// +ignore=["**", "!Cargo.toml", "!Cargo.lock", "!src/**", "!scripts/**", "!yoagent/**"]
	src *dagger.Directory) *dagger.Directory {
	return src
}

func (m *Yoke) DarwinBuild(ctx context.Context, src *dagger.Directory, version string) *dagger.File {
	container := m.withCaches(
		dag.Container().
			From("joseluisq/rust-linux-darwin-builder:latest").
			WithMountedDirectory("/app", src).
			WithWorkdir("/app"),
		"darwin-arm64",
	).
		WithExec([]string{"rustup", "update", "stable"}).
		WithExec([]string{"rustup", "default", "stable"}).
		WithExec([]string{"rustup", "target", "add", "aarch64-apple-darwin"}).
		WithExec([]string{"./scripts/cross-build-darwin.sh", "--release"})

	container = container.WithExec([]string{"sh", "-c", `
		mkdir -p /tmp/yoke-` + version + `
		cp /app/target/aarch64-apple-darwin/release/yoke /tmp/yoke-` + version + `/
		cd /tmp
		tar -czf yoke-` + version + `-darwin-arm64.tar.gz yoke-` + version + `
	`})

	return container.File("/tmp/yoke-" + version + "-darwin-arm64.tar.gz")
}

func (m *Yoke) WindowsBuild(ctx context.Context, src *dagger.Directory, version string) *dagger.File {
	container := m.withCaches(
		dag.Container().
			From("joseluisq/rust-linux-darwin-builder:latest").
			WithExec([]string{"apt", "update"}).
			WithExec([]string{"apt", "install", "-y", "nasm", "gcc-mingw-w64-i686", "mingw-w64", "mingw-w64-tools"}).
			WithExec([]string{"rustup", "target", "add", "x86_64-pc-windows-gnu"}).
			WithEnvVariable("CARGO_BUILD_TARGET", "x86_64-pc-windows-gnu").
			WithEnvVariable("CC_x86_64_pc_windows_gnu", "x86_64-w64-mingw32-gcc").
			WithEnvVariable("CXX_x86_64_pc_windows_gnu", "x86_64-w64-mingw32-g++").
			WithEnvVariable("AR_x86_64_pc_windows_gnu", "x86_64-w64-mingw32-gcc-ar").
			WithEnvVariable("DLLTOOL_x86_64_pc_windows_gnu", "x86_64-w64-mingw32-dlltool").
			WithEnvVariable("CFLAGS_x86_64_pc_windows_gnu", "-m64").
			WithEnvVariable("ASM_NASM_x86_64_pc_windows_gnu", "/usr/bin/nasm").
			WithEnvVariable("AWS_LC_SYS_PREBUILT_NASM", "0").
			WithMountedDirectory("/app", src).
			WithWorkdir("/app"),
		"windows-amd64",
	).
		WithExec([]string{"rustup", "update", "stable"}).
		WithExec([]string{"rustup", "default", "stable"}).
		WithExec([]string{"rustup", "target", "add", "x86_64-pc-windows-gnu"}).
		WithExec([]string{"cargo", "check", "--release", "--tests", "--target", "x86_64-pc-windows-gnu"}).
		WithExec([]string{"cargo", "build", "--release", "--target", "x86_64-pc-windows-gnu"})

	container = container.WithExec([]string{"sh", "-c", `
		mkdir -p /tmp/yoke-` + version + `
		cp /app/target/x86_64-pc-windows-gnu/release/yoke.exe /tmp/yoke-` + version + `/
		cd /tmp
		tar -czf yoke-` + version + `-windows-amd64.tar.gz yoke-` + version + `
	`})

	return container.File("/tmp/yoke-" + version + "-windows-amd64.tar.gz")
}

func (m *Yoke) LinuxArm64Build(ctx context.Context, src *dagger.Directory, version string) *dagger.File {
	container := m.withCaches(
		dag.Container().
			From("messense/rust-musl-cross:aarch64-musl").
			WithMountedDirectory("/app", src).
			WithWorkdir("/app"),
		"linux-arm64",
	).
		WithExec([]string{"cargo", "build", "--release", "--target", "aarch64-unknown-linux-musl"})

	container = container.WithExec([]string{"sh", "-c", `
		mkdir -p /tmp/yoke-` + version + `
		cp /app/target/aarch64-unknown-linux-musl/release/yoke /tmp/yoke-` + version + `/
		cd /tmp
		tar -czf yoke-` + version + `-linux-arm64.tar.gz yoke-` + version + `
	`})

	return container.File("/tmp/yoke-" + version + "-linux-arm64.tar.gz")
}

func (m *Yoke) LinuxAmd64Build(ctx context.Context, src *dagger.Directory, version string) *dagger.File {
	container := m.withCaches(
		dag.Container().
			From("messense/rust-musl-cross:x86_64-musl").
			WithMountedDirectory("/app", src).
			WithWorkdir("/app"),
		"linux-amd64",
	).
		WithExec([]string{"cargo", "build", "--release", "--target", "x86_64-unknown-linux-musl"})

	container = container.WithExec([]string{"sh", "-c", `
		mkdir -p /tmp/yoke-` + version + `
		cp /app/target/x86_64-unknown-linux-musl/release/yoke /tmp/yoke-` + version + `/
		cd /tmp
		tar -czf yoke-` + version + `-linux-amd64.tar.gz yoke-` + version + `
	`})

	return container.File("/tmp/yoke-" + version + "-linux-amd64.tar.gz")
}
