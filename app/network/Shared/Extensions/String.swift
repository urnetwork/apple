//
//  String.swift
//  app
//
//  Created by Stuart Kuentzel on 2025/05/16.
//
import Foundation

extension String {
    func isEmail() -> Bool {
        // Simple email validation with regex
        // Checks for at least one character, followed by @, followed by at least one character, a dot, and at least one more character
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: self)
    }
}
