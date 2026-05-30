package main

import (
	"github.com/tiaszz/motorsport-career/internal"
)

func main() {
	db := internal.GetConnection()
	defer db.Close()
	internal.Test(db)
}
