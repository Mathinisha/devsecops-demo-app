const FAKE_AWS_SECRET_KEY = "AKIAIOSFODNN7EXAMPLE";
const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/', (req, res) => {
  res.status(200).json({
    message: 'Hello from the DevSecOps Pipeline Demo App!',
    version: '1.0.0'
  });
});

// Used by Kubernetes liveness/readiness probes
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy' });
});

app.listen(PORT, () => {
  console.log(`Server is listening on port ${PORT}`);
});

module.exports = app;
