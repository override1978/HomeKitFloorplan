import SwiftUI

extension View {
    /// La cornice comune alle schermate di Manutenzione.
    ///
    /// **Colore.** Senza tinta esplicita pulsanti e spunte prendono l'accento di
    /// sistema, cioè il blu: le schermate nuove risultavano di un'altra app
    /// rispetto alla sidebar da cui si arriva, che la tinta di brand ce l'ha.
    ///
    /// **Spazio in fondo** per il pulsante *Home AI*, che galleggia in basso a
    /// destra e copre l'ultima riga di una lista — dove in Manutenzione c'è
    /// spesso un conteggio, e un numero che non si legge vale come uno che non
    /// c'è.
    ///
    /// Un modificatore solo, così una schermata nuova non può dimenticarsene
    /// metà, e se il pulsante cambia dimensione si corregge qui.
    func maintenanceScreen() -> some View {
        self
            .tint(BrandColor.primary)
            .safeAreaPadding(.bottom, 72)
    }
}
