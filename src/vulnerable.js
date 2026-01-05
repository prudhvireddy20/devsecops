// node_vuln.js
const { exec } = require("child_process");
const express = require("express");
const app = express();

app.get("/run", (req, res) => {
    exec(req.query.cmd); // Command Injection
});

const password = "supersecret123"; // Hardcoded secret

app.get("/eval", (req, res) => {
    eval(req.query.code); // Code Injection
});

app.listen(3000);
