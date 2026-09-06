# Manuel utilisateur — Meshiker

<!-- Ce document décrit toutes les fonctions de l'application Meshiker telles qu'elles existent actuellement (branche `Roadmap`). Il est structuré en questions/réponses courtes et autonomes, pensé pour servir de base à un assistant vocal ainsi qu'à l'écran d'aide in-app (lib/ui/settings/help_screen.dart) : chaque section peut être lue indépendamment pour répondre à une question précise de l'utilisateur. -->

> Meshiker est une application de randonnée conçue pour fonctionner **sans connexion internet** une fois les données locales chargées (traces, waypoints, toile de sentiers). Toutes les fonctions décrites ci-dessous sont utilisables hors réseau, sauf mention contraire explicite (chargement de tuiles de carte, abonnement).

---

## 1. Vue d'ensemble de l'écran principal

### Comment est organisé l'écran principal ?

L'écran principal est composé de la carte (toujours affichée en fond) et de trois volets accessibles en glissant le doigt sur l'écran :
- **Paramètres** (glissement vers la droite depuis la carte, ou vers la gauche en mode gaucher)
- **Navigation** (glissement vers la gauche depuis la carte, ou vers la droite en mode gaucher)
- **Roadmap** (le carnet de route de la trace en cours), accessible en continuant de glisser au-delà du volet Navigation

### Comment revenir à la carte depuis un volet ?

Glissez le doigt dans l'autre sens, ou utilisez le bouton de fermeture (croix) en haut de l'écran du volet Paramètres ou Navigation.

### Comment inverser l'interface pour un usage gaucher ?

Dans **Paramètres → Paramètres d'affichage**, activez **Mode Gaucher**. L'ordre des volets et des boutons de la carte est alors inversé.

### Comment régler la largeur des zones de balayage sur les bords de l'écran ?

Dans **Paramètres → Paramètres d'affichage**, le curseur **Zones de swipe** (20 à 80 pixels) règle la largeur de la zone tactile sur les bords de l'écran utilisée pour naviguer entre les volets, sans empêcher le geste "retour" du système Android.

### Qu'est-ce que le sélecteur GPX / MESH ?

En bas du volet Paramètres, un sélecteur à deux positions change le mode d'affichage de la carte :
- **GPX** : affiche vos traces GPX/KML importées.
- **MESH** : affiche la toile de sentiers partagée (voir section 8) et bascule la carte en mode édition du mesh.

---

## 2. La carte

### Quels boutons trouve-t-on sur la carte ?

En bas de la carte se trouve une barre d'outils. Elle peut être agrandie en glissant le doigt vers le haut dessus (ou réduite en glissant vers le bas), pour révéler une deuxième rangée de boutons.

**En mode GPX** :
- Icône de **boussole** : verrouille la rotation de la carte sur le cap du téléphone. Un nouvel appui désactive la rotation et remet la carte au nord.
- **Recentrer** (icône de ciblage) : recentre la carte sur votre position GPS actuelle et réactive le suivi automatique (désactivé dès que vous déplacez la carte manuellement).
- **GPS** : active ou désactive la localisation (texte bleu = activée, rouge = désactivée).
- **MAP** : fait défiler vos fonds de carte favoris (voir section 10).
- **Zoom −/+**.
- En rangée étendue : **afficher/masquer les waypoints**, **afficher/masquer les traces GPX**, et le bouton d'**enregistrement GPS** (voir section 3).

**En mode MESH** :
- **RECALCULER** : relance le découpage de toutes les traces stockées contre la toile de sentiers.
- **CRÉER TRACE** : fusionne les segments sélectionnés sur la carte en une nouvelle trace (nécessite d'avoir sélectionné au moins un segment en le touchant sur la carte).
- Bouton pour vider la sélection de segments.

### Comment fonctionne le bouton d'affichage des waypoints ?

Son comportement dépend de ce qui est chargé dans le Roadmap :
- **Une trace GPX est chargée dans le Roadmap** : seuls les waypoints de cette trace sont affichés par défaut ; le bouton masque ou réaffiche uniquement les waypoints de cette trace.
- **Aucune trace n'est chargée dans le Roadmap** : les waypoints de toutes les traces GPX actuellement affichées sur la carte apparaissent, et le bouton masque ou réaffiche les waypoints de l'ensemble de ces traces. Si aucune trace n'est affichée, aucun waypoint n'apparaît.

Dans les deux cas, un **appui long** sur le bouton affiche l'intégralité des waypoints existants dans le **Waypoint Manager** (dossiers personnels compris), et un appui simple suivant revient à l'affichage de départ.

### Comment sélectionner un segment du mesh sur la carte ?

En mode MESH, touchez un tracé sur la carte : il se met en surbrillance verte. Touchez-le à nouveau pour le désélectionner.

### Que se passe-t-il si je fais un appui long sur la carte ?

Un appui long ouvre la fiche de création d'un nouveau waypoint à l'endroit touché (voir section 4).

### Que se passe-t-il si je touche un marqueur waypoint sur la carte ?

Cela ouvre la fiche de ce waypoint pour la consulter ou la modifier.

### Que se passe-t-il si je touche un point d'intérêt (POI) affiché par OpenStreetMap ?

Une fiche de waypoint s'ouvre, pré-remplie avec le nom et la position du point d'intérêt, pour vous permettre de l'adopter comme waypoint personnel si vous l'enregistrez.

### La carte affiche "Pas de connexion internet : carte indisponible", que faire ?

Cela signifie que les tuiles de la carte n'ont pas pu être chargées (pas de réseau, et rien n'est encore disponible en local pour cette zone). Un bouton **Réessayer** permet de retenter le chargement.

---

## 3. Enregistrer une randonnée (GPS)

### Comment démarrer un enregistrement GPS ?

Sur la carte, en mode GPX, appuyez sur le bouton d'enregistrement (rond rouge) dans la rangée étendue de la barre d'outils. La localisation doit être activée au préalable (bouton **GPS**), sinon un message vous le rappelle et l'enregistrement ne démarre pas.

### Que se passe-t-il pendant un enregistrement ?

L'application suit votre position en continu (y compris en arrière-plan, grâce à une notification persistante) et met à jour en direct les statistiques affichées dans le volet Navigation : vitesse, distance parcourue, précision GPS, nombre de satellites, podomètre, heures de lever/coucher du soleil.

### Comment arrêter un enregistrement ?

Appuyez de nouveau sur le bouton d'enregistrement (devenu un carré rouge). Une fenêtre vous demande de nommer la randonnée (un nom par défaut avec la date est proposé) puis deux choix :
- **ENREGISTRER** : sauvegarde la trace parcourue.
- **ANNULER** : après une confirmation supplémentaire, supprime définitivement les données de la session.

### Que se passe-t-il si l'application est fermée pendant un enregistrement ?

La session est conservée et peut être reprise ou annulée au prochain lancement de l'application.

### Puis-je mettre en pause un enregistrement ?

Non, cette fonction n'est pas encore accessible depuis l'interface actuelle. Seuls le démarrage et l'arrêt sont disponibles.

---

## 4. Les waypoints (points d'intérêt)

### Comment créer un waypoint ?

Faites un appui long sur la carte à l'endroit souhaité : la fiche de création s'ouvre.

### Que peut-on renseigner sur un waypoint ?

- **Nom** (obligatoire)
- **Catégorie** (parmi celles définies dans les paramètres, ou aucune)
- **Description** (facultative)
- **Couleur** du marqueur (sélecteur de couleurs)
- **Photos** : prises directement avec l'appareil photo (pas d'import depuis la galerie) ; la première photo ajoutée sert de photo principale, vous pouvez en choisir une autre en la touchant dans la grille.

### Comment consulter ou modifier un waypoint existant ?

Touchez son marqueur sur la carte, ou retrouvez-le dans le **Waypoint Manager** (Paramètres → Waypoint Manager) et touchez sa ligne.

### Comment gérer plusieurs waypoints à la fois (déplacer, supprimer) ?

Dans le **Waypoint Manager**, faites un appui long sur un waypoint pour entrer en mode sélection multiple, puis touchez d'autres waypoints pour les ajouter à la sélection. Une barre d'actions apparaît :
- **DÉPLACER** : range les waypoints sélectionnés dans un dossier personnel, hors de tout dossier, ou dans le groupe d'une trace GPX.
- **SUPPRIMER** : supprime les waypoints sélectionnés après confirmation.

### Comment rechercher un waypoint ?

Dans le Waypoint Manager, utilisez la barre de recherche (filtre par nom) et le menu déroulant de filtre par catégorie.

### Comment créer ou gérer les catégories de waypoints ?

Dans le Waypoint Manager, l'icône d'engrenage ouvre la gestion des catégories : création (bouton +), modification du nom/icône/couleur en touchant une catégorie, et réorganisation par glisser-déposer.

### Comment masquer les waypoints d'une trace GPX dans la liste ?

Dans la gestion des catégories, désactivez **Afficher les waypoints GPX** pour ne voir dans le Waypoint Manager que les waypoints indépendants.

---

## 5. Les traces GPX/KML

### Comment mes traces GPX/KML arrivent-elles dans l'application ?

En déposant vos fichiers `.gpx` ou `.kml` dans le dossier configuré dans **Paramètres → Paramètres système → Stockage GPX/KML**. L'application scanne ce dossier automatiquement au démarrage.

### Comment configurer le dossier de mes traces ?

Dans **Paramètres → Paramètres système**, section **Stockage GPX/KML**, bouton **Sélectionner**. Vous pouvez aussi définir un sous-dossier dédié aux nouveaux enregistrements.

### Comment forcer une nouvelle analyse du dossier sans redémarrer l'application ?

Dans le **Track Manager**, appuyez sur l'icône d'actualisation en haut de l'écran.

### Combien de temps prend l'import d'une trace ?

La trace apparaît immédiatement dans la liste (avec une icône de chargement), le temps que son découpage en segments (intégration à la toile de sentiers) se termine en arrière-plan. Une fois prête, la distance et le dénivelé s'affichent.

### Comment charger une trace pour la suivre (mode navigation) ?

Ouvrez la trace dans le **Track Manager**, touchez-la pour ouvrir sa fiche, puis dans le menu (⋮) choisissez **Naviguer**. La trace devient alors la trace active du **Roadmap** (voir section 6).

### Comment activer/désactiver l'affichage d'une trace sur la carte ?

Dans le Track Manager, chaque trace a un interrupteur qui l'active ou la désactive sur la carte.

### Que peut-on faire depuis le menu (⋮) d'une trace ?

- **Naviguer** : charge la trace dans le Roadmap.
- **Couleur de la trace** : change sa couleur d'affichage.
- **Déplacer** : déplace le fichier source vers un autre dossier de l'appareil.
- **Supprimer** : supprime définitivement la trace et son fichier source (action irréversible, confirmation demandée).
- **Créer carte hors-ligne** et **Profil altimétrique** : fonctionnalités à venir, pas encore disponibles.

### Comment trier ou rechercher mes traces ?

Le Track Manager propose une barre de recherche par nom et un tri : ordre alphabétique, distance croissante/décroissante, dénivelé positif/négatif/cumulé.

---

## 6. Le Roadmap (carnet de route)

### À quoi sert le Roadmap ?

Le Roadmap affiche, dans l'ordre du parcours, tous les waypoints de la trace actuellement chargée (via "Naviguer"), avec la distance vous séparant de chacun.

### Comment savoir où j'en suis sur ma trace ?

Une ligne verte matérialise votre progression dans la liste et descend automatiquement à mesure que vous dépassez les waypoints (dépassés = grisés).

### Comment choisir un point d'étape sur la trace ?

Depuis le volet Navigation, bouton **Choisir un point** (section Destination) : ouvre le Roadmap en mode sélection — touchez un waypoint pour en faire votre destination.

### Le Roadmap est vide, pourquoi ?

Aucune trace n'est chargée. Ouvrez une trace depuis le Track Manager et choisissez "Naviguer".

---

## 7. La météo

### Comment consulter la météo ?

Dans le volet Navigation, la carte **Météo** fonctionne comme le podomètre :

- **Un appui** l'active (et lance le premier chargement) ou la rafraîchit. Le cadre s'épaissit quand elle est active. L'icône affichée résume la **tendance des 4 prochaines heures** : s'il fait beau maintenant mais qu'une averse arrive dans 2 h, c'est l'icône de pluie qui s'affiche.
- **Un double appui** ouvre la **page Météo** en plein écran.

### Qu'affiche la page Météo ?

- **Aujourd'hui** : heure par heure jusqu'à minuit, avec icône, risque de pluie, millimètres, vent, température (et ressenti) et pression.
- **4 jours suivants** : une ligne par jour (icône, mini/maxi, risque de pluie). Touchez une ligne pour dérouler le détail **jour (7 h–19 h) / nuit (19 h–7 h)**.

### Prévisions le long d'une trace (Premium)

Avec un abonnement Premium **et** une trace chargée via « Naviguer », la section « Aujourd'hui » ne se limite plus à votre position : elle place un point de prévision par heure restante **le long du parcours**, en tenant compte de votre vitesse (celle de la sortie en cours si disponible, sinon votre moyenne historique, sinon 4,5 km/h), et affiche le kilométrage de chaque point. Sans trace chargée, la page reste centrée sur votre position actuelle.

### La météo est indisponible

La météo nécessite une connexion internet : en zone blanche, la page l'indique et aucune donnée n'est chargée. Le reste de l'application fonctionne normalement hors-ligne.

### Unités

La météo suit le réglage **Unités de mesure** métrique/impérial des Paramètres système (le même que pour le reste de l'application). La pression est toujours en hPa.

---

## 8. Le mode Mesh (toile de sentiers partagée)

### Qu'est-ce que le mesh ?

C'est la toile de sentiers reconstituée à partir de toutes vos traces GPX importées et enregistrées : chaque trace est découpée en segments qui se rattachent aux segments déjà connus à proximité, plutôt que d'être stockée comme une ligne isolée.

### Comment voir et éditer le mesh ?

Basculez le sélecteur d'affichage sur **MESH** (bas du volet Paramètres). Les outils d'édition (sélection de segments, RECALCULER, CRÉER TRACE) apparaissent alors dans la barre d'outils de la carte (voir section 2).

### Comment consulter la liste brute des segments enregistrés ?

**Paramètres → Mesh manager** affiche la liste de tous les segments avec leur distance et dénivelé, et permet de supprimer un segment individuellement.

---

## 9. Mesure de distance et d'azimut

### Comment mesurer une distance depuis ma position ?

Volet Navigation → section **Azimut et distance** → **Depuis ma position GPS**. La carte affiche une ligne entre votre position et une croix que vous positionnez en déplaçant la carte ; la distance et l'azimut s'affichent en direct dans la barre du bas.

### Comment mesurer une distance entre deux points quelconques ?

Volet Navigation → **Entre deux points**. Positionnez la croix sur le premier point et validez, puis faites de même pour le second point.

### Comment annuler une mesure en cours ?

Appuyez sur la croix (✕) affichée à gauche de la barre d'outils pendant une mesure.

---

## 10. Les cartes hors-ligne

### Comment choisir mon fond de carte ?

**Paramètres → Mes cartes**, onglet **Fonds de carte** : cochez jusqu'à 3 fonds de carte favoris (OpenStreetMap, OpenTopoMap, CyclOSM, Google Satellite, ArcGIS Satellite). Le bouton **MAP** de la carte fait défiler ces favoris dans l'ordre choisi.

### Comment télécharger une zone pour une utilisation hors-ligne ?

**Paramètres → Mes cartes**, onglet **Hors ligne**, bouton **Créer une carte** :
1. Positionnez la croix rouge sur le point de départ de la zone et validez.
2. Éloignez-vous pour définir l'étendue de la zone et validez.
3. Ajustez la zone (flèches directionnelles) et la plage de niveaux de zoom à télécharger, puis enregistrez (nom + description).

> Cette fonctionnalité est en cours de finalisation : le téléchargement réel des tuiles n'est pas encore pleinement opérationnel dans cette version.

### Comment supprimer une carte hors-ligne ?

Dans la liste des cartes hors-ligne, appuyez sur l'icône de suppression sur la ligne correspondante.

### Comment ouvrir mon fichier `.mbtiles` personnel ?

Un bouton **Importer** existe dans l'onglet Hors-ligne, mais cette fonction n'est pas encore opérationnelle dans cette version.

---

## 11. Paramètres d'affichage

Accessible via **Paramètres → Paramètres d'affichage**.

- **Transparence menu Paramètres/Outils** et **Transparence menu principal** : réglages indépendants de l'opacité des volets et de la barre d'outils de la carte.
- **Afficher l'échelle** : affiche/masque l'échelle graphique sur la carte.
- **Mode Gaucher** : voir section 1.
- **Zones de swipe** : voir section 1.
- **Taille icônes Waypoints** : ajuste la taille des marqueurs sur la carte.
- **Ouverture de la carte** : choisissez si l'application rouvre sur la dernière position consultée, ou sur un point personnalisé que vous définissez en touchant la carte.
- **Épaisseur du trait sur la carte** (section Traces) : de 1 à 10 pixels, s'applique aux traces GPX affichées et à la trace en cours d'enregistrement.
- **Couleur par défaut des traces** (section Traces) : couleur appliquée aux traces GPX/KML qui n'ont pas de couleur propre définie dans le Track Manager.
- **Personnaliser le volet de navigation** : active/désactive individuellement chaque bloc d'information du volet Navigation (vitesse, distance du jour, distances sur la trace, précision GPS, satellites, podomètre, prochain waypoint, destination, outils de mesure).

---

## 12. Paramètres système

Accessible via **Paramètres → Paramètres système**.

- **Unités de mesure** : un seul choix métrique/impérial pour toute l'application — distances, altitudes, et météo (température, vent, précipitations). La pression reste en hPa.
- **Stockage GPX/KML** : dossier source des traces et sous-dossier d'enregistrement (voir section 5).
- **Cache des cartes** : limite de taille (100 à 5000 Mo) et bouton pour vider le cache de tuiles.
- **Réseau et téléchargement** : option pour restreindre les téléchargements de cartes hors-ligne au Wi-Fi.
- **Photos** : les photos prises dans l'application sont enregistrées dans la galerie du téléphone (dossier "Images/Meshiker") ; un bouton permet de resynchroniser la bibliothèque de photos avec l'application.

---

## 13. Mon compte et abonnement

Accessible via **Paramètres → Mon compte**.

- Affiche votre profil (pseudo, email si renseigné) et votre statut d'abonnement (gratuit/premium).
- **Voir les offres Premium** ou **Gérer mon abonnement** selon votre statut, et **Restaurer mes achats**.
- Indique si l'appareil est connecté au service de synchronisation communautaire ou en mode local uniquement.
- Accès aux **Conditions d'utilisation** via le lien "À propos".

---

## 14. Aide

**Paramètres → Aide** affiche ce manuel utilisateur dans son intégralité. Pour un compte Premium avec l'assistant IA activé, une barre de question rapide reste ancrée en bas de l'écran pour poser directement une question à l'assistant sans quitter l'aide.

---

## Fonctionnalités mentionnées dans l'interface mais pas encore disponibles

Pour éviter toute confusion, voici les éléments visibles dans l'application mais non fonctionnels à ce jour :
- **Créer carte hors-ligne** et **Profil altimétrique** (menu d'une trace) : grisés, à venir.
- **Importer** un fichier `.mbtiles` (Mes cartes → Hors ligne) : ouvre un sélecteur de fichier mais n'importe rien encore.
- Le téléchargement réel des tuiles pour une carte hors-ligne créée via "Créer une carte" n'est pas encore pleinement opérationnel.
- La mise en pause d'un enregistrement GPS en cours n'est pas accessible depuis l'interface.
- Le tri "Proximité" des traces (Track Manager) se comporte actuellement comme un tri alphabétique.
