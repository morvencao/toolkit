import (
	"flag"
	"fmt"
	"io"
	"net/http"
	"sync"

    "github.com/Shopify/sarama"
)

var (
	wg  sync.WaitGroup
	port = flag.Int("port", 9080, "The http server port.")
	kafkaSvr = flag.String("kafka-server-address", "localhost", "The address for kafaka server, if not set, use localhost instead.")
	kafkaPort = flag.Int("kafka-port", 9092, "The port for kafka server, default valus is 9092.")
)

func main() {
	flag.Parse()

	http.HandleFunc("/", consumerHandler)
	http.ListenAndServe(fmt.Sprintf("0.0.0.0:%v", *port), nil)
}

func consumerHandler(w http.ResponseWriter, r *http.Request) {
    consumer, err := sarama.NewConsumer([]string{kafkaSvr + "" + kafkaPort}, nil)
    if err != nil {
        panic(err)
	}

    partitionList, err := consumer.Partitions("test")
    if err != nil {
        panic(err)
	}

    for partition := range partitionList {
        pc, err := consumer.ConsumePartition("test", int32(partition), sarama.OffsetNewest)
        if err != nil {
            panic(err)
        }
        defer pc.AsyncClose()
        wg.Add(1)
        go func(sarama.PartitionConsumer) {
            defer wg.Done()
            for msg := range pc.Messages() {
				fmt.Fprintf(w, "%s---Partition:%d, Offset:%d, Key:%s, Value:%s\n", msg.Topic,msg.Partition, msg.Offset, string(msg.Key), string(msg.Value))
            }
        }(pc)
    }
    wg.Wait()
    consumer.Close()
}
