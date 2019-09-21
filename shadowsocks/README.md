## SS Chart

helm chart for ss.

### Requirements

1. kubectl
2. helm

### Install

1. (option1)install with `helm template`(without tiller) + `kubectl`
```
kubectl create ns ss-system
helm template --name ss --namespace ss-system ./shadowsocks | kubectl apply -f -
```

2. (option2)install with `helm install`(without tiller) + `kubectl`
```
kubectl create ns ss-system
helm install --name ss --namespace ss-system ./shadowsocks
```
