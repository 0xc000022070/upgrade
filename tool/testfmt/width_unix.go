//go:build linux || darwin

package main

import (
	"os"
	"syscall"
	"unsafe"
)

func width(f *os.File) int {
	var size struct{ rows, cols, x, y uint16 }
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), syscall.TIOCGWINSZ, uintptr(unsafe.Pointer(&size)))
	if errno != 0 {
		return 0
	}
	return int(size.cols)
}
