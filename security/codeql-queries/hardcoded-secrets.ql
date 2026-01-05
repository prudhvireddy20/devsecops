/**
 * @name Hardcoded secret
 * @description Detects hardcoded credentials and secrets
 * @kind problem
 * @problem.severity error
 * @security-severity 7.5
 * @precision high
 * @id java/hardcoded-secret
 * @tags security
 *       external/cwe/cwe-798
 */

import java

class HardcodedSecret extends Literal {
  HardcodedSecret() {
    this instanceof StringLiteral and
    this.getValue().length() > 6 and
    this.getValue().matches("(?i).*(password|passwd|pwd|secret|token|apikey|key).*")
  }
}

from VariableDeclarator var, HardcodedSecret secret
where
  var.getInitializer() = secret
select var,
  "Hardcoded secret detected: " + secret.getValue()
