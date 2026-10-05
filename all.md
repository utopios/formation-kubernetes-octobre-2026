NAME                              READY   STATUS    RESTARTS   AGE
pod/trackr-api-64f4f8d574-8zz5l   1/1     Running   0          34m
pod/trackr-api-64f4f8d574-pmr4j   1/1     Running   0          33m
pod/trackr-api-64f4f8d574-qd57c   1/1     Running   0          33m

NAME                 TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/kubernetes   ClusterIP   10.96.0.1      <none>        443/TCP    16h
service/trackr-api   ClusterIP   10.96.62.148   <none>        9898/TCP   28m

NAME                         READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/trackr-api   3/3     3            3           40m

NAME                                    DESIRED   CURRENT   READY   AGE
replicaset.apps/trackr-api-64f4f8d574   3         3         3       36m
