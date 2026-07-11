package proxy

import (
    "context"
    "fmt"
    "io"
    "net"
    "net/http"
    "time"

    "github.com/gorilla/websocket"
    "github.com/tunnelgate/tunnelgate/internal/config"
    "github.com/tunnelgate/tunnelgate/internal/logger"
    "github.com/tunnelgate/tunnelgate/internal/user"
)

var upgrader = websocket.Upgrader{
    CheckOrigin: func(r *http.Request) bool { return true },
    // Increase buffer sizes for better performance
    ReadBufferSize:  4096,
    WriteBufferSize: 4096,
}

func Start(ctx context.Context, cfg *config.Config) error {
    mux := http.NewServeMux()
    mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        handleProxy(w, r, cfg)
    })

    addr := fmt.Sprintf("%s:%d", cfg.Proxy.ListenHost, cfg.Proxy.ListenPort)
    srv := &http.Server{
        Addr:         addr,
        Handler:      mux,
        ReadTimeout:  10 * time.Second,
        WriteTimeout: 10 * time.Second,
        IdleTimeout:  time.Duration(cfg.Proxy.IdleTimeout) * time.Second,
    }

    logger.Info("Proxy listening", "addr", addr)

    errChan := make(chan error, 1)
    go func() {
        if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
            errChan <- err
        }
    }()

    select {
    case <-ctx.Done():
        logger.Info("Proxy shutting down...")
        shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        return srv.Shutdown(shutdownCtx)
    case err := <-errChan:
        return err
    }
}

func handleProxy(w http.ResponseWriter, r *http.Request, cfg *config.Config) {
    // Optional Basic Auth
    username, password, ok := r.BasicAuth()
    if ok {
        db := user.OpenDB(cfg.Database)
        if !user.Authenticate(db, username, password) {
            logger.Warn("Authentication failed", "username", username, "remote", r.RemoteAddr)
            http.Error(w, "Unauthorized", http.StatusUnauthorized)
            return
        }
    }

    conn, err := upgrader.Upgrade(w, r, nil)
    if err != nil {
        logger.Error("WebSocket upgrade failed", "error", err, "remote", r.RemoteAddr)
        return
    }
    defer conn.Close()

    // Connect to backend with retry
    backendAddr := fmt.Sprintf("%s:%d", cfg.BackendHost, cfg.BackendPort)
    var backend net.Conn
    var backendErr error
    for attempt := 1; attempt <= 3; attempt++ {
        backend, backendErr = net.DialTimeout("tcp", backendAddr, 5*time.Second)
        if backendErr == nil {
            break
        }
        logger.Warn("Backend connect attempt failed",
            "attempt", attempt, "error", backendErr, "addr", backendAddr)
        time.Sleep(time.Duration(attempt*2) * time.Second)
    }
    if backendErr != nil {
        logger.Error("Backend unreachable", "error", backendErr, "addr", backendAddr)
        conn.WriteMessage(websocket.CloseMessage, []byte("backend unavailable"))
        return
    }
    defer backend.Close()

    logger.Info("Proxy connection established", "remote", r.RemoteAddr, "backend", backendAddr)

    errChan := make(chan error, 2)

    // Reader: WebSocket -> backend
    go func() {
        defer func() {
            if r := recover(); r != nil {
                logger.Error("Panic in proxy reader", "panic", r)
                errChan <- fmt.Errorf("reader panic: %v", r)
            }
        }()
        for {
            msgType, data, err := conn.ReadMessage()
            if err != nil {
                errChan <- err
                return
            }
            if msgType != websocket.BinaryMessage && msgType != websocket.TextMessage {
                continue
            }
            if _, err := backend.Write(data); err != nil {
                errChan <- err
                return
            }
        }
    }()

    // Writer: backend -> WebSocket
    go func() {
        defer func() {
            if r := recover(); r != nil {
                logger.Error("Panic in proxy writer", "panic", r)
                errChan <- fmt.Errorf("writer panic: %v", r)
            }
        }()
        if _, err := io.Copy(conn.UnderlyingConn(), backend); err != nil {
            errChan <- err
        }
    }()

    // Wait for any error
    if err := <-errChan; err != nil {
        logger.Debug("Proxy relay ended", "error", err)
    }
    // Send close frame to client
    conn.WriteMessage(websocket.CloseMessage, []byte{})
}
