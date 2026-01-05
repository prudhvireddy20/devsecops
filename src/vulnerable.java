// Vuln.java
import java.sql.*;
import java.io.*;

public class Vuln {
    public static void main(String[] args) throws Exception {
        String user = args[0];

        Statement stmt = DriverManager
            .getConnection("jdbc:mysql://localhost/test", "root", "root")
            .createStatement();

        stmt.execute("SELECT * FROM users WHERE name = '" + user + "'"); // SQL Injection

        Runtime.getRuntime().exec(user); // Command Injection
    }
}
