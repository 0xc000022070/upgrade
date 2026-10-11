//go:build !(linux || darwin)

package main

import "os"

func width(*os.File) int { return 0 }
