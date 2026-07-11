package user

import (
    "database/sql"
    "errors"
    "fmt"
    "time"

    _ "github.com/mattn/go-sqlite3"
    "golang.org/x/crypto/bcrypt"
)

type User struct {
    ID       int
    Username string
    Password string // hashed
    Expiry   time.Time
    Locked   bool
}

var db *sql.DB

func InitDB(path string) (*sql.DB, error) {
    var err error
    db, err = sql.Open("sqlite3", path)
    if err != nil {
        return nil, fmt.Errorf("open db: %w", err)
    }
    _, err = db.Exec(`
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            expiry DATETIME NOT NULL,
            locked BOOLEAN DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_username ON users(username);
    `)
    if err != nil {
        return nil, fmt.Errorf("create table: %w", err)
    }
    return db, nil
}

func OpenDB(path string) *sql.DB {
    if db == nil {
        var err error
        db, err = InitDB(path)
        if err != nil {
            panic(err)
        }
    }
    return db
}

func Authenticate(db *sql.DB, username, password string) bool {
    var hash string
    row := db.QueryRow("SELECT password_hash FROM users WHERE username = ? AND locked = 0 AND expiry > datetime('now')", username)
    if err := row.Scan(&hash); err != nil {
        return false
    }
    err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
    return err == nil
}

func AddUser(db *sql.DB, username, password string, days int) (*User, error) {
    if username == "" {
        return nil, errors.New("username cannot be empty")
    }
    if len(password) < 6 {
        return nil, errors.New("password must be at least 6 characters")
    }

    hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
    if err != nil {
        return nil, fmt.Errorf("hash password: %w", err)
    }

    expiry := time.Now().AddDate(0, 0, days)
    tx, err := db.Begin()
    if err != nil {
        return nil, fmt.Errorf("begin tx: %w", err)
    }
    defer tx.Rollback()

    res, err := tx.Exec("INSERT INTO users (username, password_hash, expiry) VALUES (?, ?, ?)",
        username, hash, expiry.Format(time.RFC3339))
    if err != nil {
        return nil, fmt.Errorf("insert user: %w", err)
    }

    id, _ := res.LastInsertId()
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("commit tx: %w", err)
    }

    return &User{ID: int(id), Username: username, Expiry: expiry, Locked: false}, nil
}

func ListUsers(db *sql.DB) ([]User, error) {
    rows, err := db.Query("SELECT id, username, expiry, locked FROM users ORDER BY username")
    if err != nil {
        return nil, fmt.Errorf("query users: %w", err)
    }
    defer rows.Close()
    var users []User
    for rows.Next() {
        var u User
        var expiryStr string
        rows.Scan(&u.ID, &u.Username, &expiryStr, &u.Locked)
        u.Expiry, _ = time.Parse(time.RFC3339, expiryStr)
        users = append(users, u)
    }
    return users, nil
}

func CountUsers(db *sql.DB) (int, error) {
    var count int
    err := db.QueryRow("SELECT COUNT(*) FROM users").Scan(&count)
    if err != nil {
        return 0, fmt.Errorf("count users: %w", err)
    }
    return count, nil
}
