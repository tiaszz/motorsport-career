package internal

import (
	"database/sql"
	"fmt"
	"log"
	"os"

	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
)

func GetConnection() *sql.DB {
	err := godotenv.Load()
	if err != nil {
		log.Fatal("Error loading .env file")
	}

	var USER_DB string = os.Getenv("POSTGRES_USER")
	var PASSWORD_DB string = os.Getenv("POSTGRES_PASSWORD")
	var DB_NAME string = os.Getenv("POSTGRES_DB")
	var HOST string = "localhost"
	var PORT string = "5432"

	connDB := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable", HOST, PORT, USER_DB, PASSWORD_DB, DB_NAME)
	db, err := sql.Open("postgres", connDB)
	if err != nil {
		log.Fatalln("Error getting connection:", err)
	}
	return db
}

func Test(db *sql.DB) {
	query := "SELECT * FROM car_category"
	rows, err := db.Query(query)
	if err != nil {
		log.Fatalf("err: %v", err)
	}
	defer rows.Close()

	for rows.Next() {
		var id int
		var code string
		var displayName string
		var parentCategory string
		var suggestPriceMin int
		var suggestPriceMax int
		var repairCostMultiplier float64
		var notes string

		err := rows.Scan(&id, &code, &displayName, &parentCategory, &suggestPriceMin, &suggestPriceMax, &repairCostMultiplier, &notes)
		if err != nil {
			log.Fatal(err)
		}

		fmt.Printf("id: %d\ncode: %s\ndisplay name: %s\nparent category: %s\nsuggest price min: %d\nsuggest price max: %d\nrepair cost multi: %f\nnotes: %s", id, code, displayName, parentCategory, suggestPriceMin, suggestPriceMax, repairCostMultiplier, notes)
	}
}
