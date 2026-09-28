apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: egfw-validation
spec:
  role: ${CLUSTER_NAME}
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: egfw-validation
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: egfw-validation
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: [amd64]
        - key: karpenter.sh/capacity-type
          operator: In
          values: [spot]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: [t3.large, t3a.large, m5.large, m5a.large]
  limits:
    cpu: "8"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: egfw-replacement
spec:
  replicas: 1
  selector:
    matchLabels:
      app: egfw-replacement
  template:
    metadata:
      labels:
        app: egfw-replacement
    spec:
      nodeSelector:
        karpenter.sh/nodepool: egfw-validation
      containers:
        - name: probe
          image: public.ecr.aws/docker/library/busybox:1.37.0
          command: [sh, -c, "sleep 3600"]
