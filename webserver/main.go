package main

import (
	"flag"
    "fmt"
    "net/http"
)

func hello(w http.ResponseWriter, req *http.Request) {
    fmt.Fprintf(w, "hello\n")
}

func headers(w http.ResponseWriter, req *http.Request) {
    for name, headers := range req.Header {
        for _, h := range headers {
            fmt.Fprintf(w, "%v: %v\n", name, h)
        }
    }
}

func main() {
	var certFilePath, keyFilePath string
	flag.StringVar(&certFilePath, "cert-path", "/certs/tls.crt", "certificate path")
	flag.StringVar(&keyFilePath, "key-path", "/certs/tls.key", "key path")
	flag.Parse()

	fmt.Println("cert path:", certFilePath)
    fmt.Println("key path:", keyFilePath)

    http.HandleFunc("/hello", hello)
    http.HandleFunc("/headers", headers)

    http.ListenAndServeTLS(":8080", certFilePath, keyFilePath, nil)
}
