import AzureFishAPI

@MainActor
func contactErrorKey(_ error: any Error) -> String {
    if let error = error as? ContactOperationError {
        switch error {
        case .confirmedPrevious, .resultExpired: return "contacts.reconciled"
        case .busy: return "contacts.busy"
        case .unavailable: return "contacts.unavailable"
        }
    }
    if case APIClientError.service(let failure) = error {
        switch failure.code {
        case .selfContact: return "chat.live.selfContact"
        case .userNotFound: return "contacts.notFound"
        case .rateLimited: return "contacts.rateLimited"
        case .contactClientUpdateRequired: return "contacts.updateRequired"
        case .contactVersionConflict, .contactActionUnavailable: return "chat.live.changed"
        case .contactUnavailable: return "contacts.unavailable"
        case .validationFailed: return "contacts.invalidInput"
        default: return "chat.live.failed"
        }
    }
    return "contacts.networkError"
}
