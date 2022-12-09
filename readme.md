Inside container check mount points.

kubectl apply -f efs-writer.yaml
kubectl apply -f efs-reader.yaml


kubectl exec -it efs-writer -- tail /shared/out.txt
kubectl exec -it efs-reader -- tail /shared/out.txt


Reference url :

https://computingforgeeks.com/eks-persistent-storage-with-efs-aws-service/

https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html



kubectl apply -f efs-writer.yaml
kubectl apply -f efs-reader.yaml