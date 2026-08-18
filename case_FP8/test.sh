MODEL="Qwen/Qwen3.8-27B-FP8"
DOMAIN="llm.yacodata.com"

echo "=== Test 1: Direct HTTPS via Envoy AI Gateway ==="
curl -X POST "https://${DOMAIN}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: ${MODEL}" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Write a hello world in Python\"}],
    \"max_tokens\": 100
  }" | jq -r '.choices[0].message.content' | sed 's/Ġ/ /g; s/Ċ/\n/g'

echo ""
echo "=== Test 2: AI Gateway model-based routing via header ==="
curl -s -X POST "https://${DOMAIN}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: ${MODEL}" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word\"}],
    \"max_tokens\": 50
  }" | jq .

echo ""
echo "=== Test 3: Direct NodePort (bypass TLS) ==="
curl -s -X POST "https://${DOMAIN}:30080/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Write Python class for sum and product of two numbers\"}],
    \"max_tokens\": 500
  }" | jq -r '.choices[0].message.content' | sed 's/Ġ/ /g; s/Ċ/\n/g'

echo ""
echo "=== Test 4: Advanced math (Fourier transform) ==="
curl -X POST "https://${DOMAIN}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Compute the Fourier transform of f(x)=e^{-⟨Ax,x⟩} for A positive definite\"}],
    \"max_tokens\": 500
  }" | jq -r '.choices[0].message.content' | sed 's/Ġ/ /g; s/Ċ/\n/g'

echo ""
echo "=== Test 5: Direct vLLM (in-cluster via kubectl exec) ==="
echo "# kubectl run -n beta curl-test --image=curlimages/curl --rm -it --restart=Never --"
echo "#   -s http://llm-server-kserve-workload-svc.beta.svc.cluster.local:8000/v1/chat/completions"
echo "#   -H \"Content-Type: application/json\""
echo "#   -d '{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":10}'"

# Clean up evicted/completed pods
kubectl get pods --all-namespaces --field-selector=status.phase=Failed -o json | \
  jq -r '.items[] | select(.status.reason == "Completed") | .metadata.namespace + " " + .metadata.name' | \
  while read -r namespace name; do
    kubectl delete pod "$name" -n "$namespace"
  done
