import SwiftUI

extension View {
    /// Spazio in fondo per il pulsante **Home AI**, che galleggia in basso a
    /// destra e copre l'ultima riga di una lista.
    ///
    /// In Manutenzione l'ultima riga porta spesso un conteggio, e un numero che
    /// non si legge vale come un numero che non c'è. Un modificatore con un nome
    /// invece dello stesso valore ripetuto ovunque: se il pulsante cambia
    /// dimensione, si corregge qui.
    func maintenanceBottomClearance() -> some View {
        safeAreaPadding(.bottom, 72)
    }
}
