package main

import (
	"flag"
	"fmt"
	"html"
	"log"
	"net/http"

    "github.com/Shopify/sarama"
)

var (
	port = flag.Int("port", 9080, "The http server port.")
	kafkaSvr = flag.String("kafka-server-address", "localhost", "The address for kafaka server, if not set, use localhost instead.")
	kafkaPort = flag.Int("kafka-port", 9092, "The port for kafka server, default valus is 9092.")
	kafkaTopic = flag.String("kafka-topic", "test", "The topic for kafka.")
)

func main() {
	flag.Parse()

	kafkaURL := fmt.Sprintf("%s:%d", *kafkaSvr, *kafkaPort)
	brokers := []string{kafkaURL}

	producer, err := newProducer(brokers)
	if err != nil {
		fmt.Println("Could not create producer: ", err)
	}

	consumer, err := sarama.NewConsumer(brokers, nil)
	if err != nil {
		fmt.Println("Could not create consumer: ", err)
	}

	subscribe(*kafkaTopic, consumer)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "Hello Sarama!") })

	http.HandleFunc("/save", func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		r.ParseForm()
		msg := prepareMessage(*kafkaTopic, r.FormValue("q"))
		partition, offset, err := producer.SendMessage(msg)
		if err != nil {
			fmt.Fprintf(w, "%s error occured.", err.Error())
		} else {
			fmt.Fprintf(w, "Message was saved to partion: %d.\nMessage offset is: %d.\n", partition, offset)
		}
	})

	http.HandleFunc("/retrieve", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, html.EscapeString(getMessage())) })

	log.Fatal(http.ListenAndServe(fmt.Sprintf("0.0.0.0:%v", *port), nil))
}
