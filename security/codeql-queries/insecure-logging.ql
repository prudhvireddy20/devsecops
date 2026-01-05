/**
 * @name Insecure logging of sensitive data
 * @description Detects logging of potentially sensitive information
 * @kind problem
 * @problem.severity warning
 * @security-severity 6.0
 * @precision medium
 * @id java/insecure-logging
 * @tags security
 *       external/cwe/cwe-532
 */

import java
import semmle.code.java.security.Logging

class SensitiveVariable extends Expr {
  SensitiveVariable() {
    exists(string name |
      name = this.toString() and
      name.matches("(?i).*(password|passwd|pwd|secret|token|key|credential).*")
    )
  }
}

from MethodAccess logCall, SensitiveVariable sensitive
where
  logCall.getMethod().getName().matches("(?i)(info|debug|warn|error|println)") and
  logCall.getArgument(_) = sensitive
select logCall,
  "Sensitive data may be logged here: " + sensitive.toString()
