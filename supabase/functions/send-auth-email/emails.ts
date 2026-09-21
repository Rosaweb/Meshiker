// Contenu des emails d'authentification, par langue. Volontairement PUR (aucune
// API Deno, aucun réseau) pour rester testable avec Node — voir index.ts pour
// l'envoi. Pour ajouter une langue : l'ajouter à SUPPORTED_LOCALES et fournir
// son bloc dans COPY (le compilateur signale les clés manquantes).

export const SUPPORTED_LOCALES = ['fr', 'en'] as const;
export type Locale = (typeof SUPPORTED_LOCALES)[number];
export const DEFAULT_LOCALE: Locale = 'en';

/// Types d'emails gérés par le hook. `invite` est traité comme `signup`.
export type EmailKind =
  | 'signup'
  | 'recovery'
  | 'email_change'
  | 'magiclink'
  | 'reauthentication';

export function emailKindFor(actionType: string): EmailKind | null {
  switch (actionType) {
    case 'signup':
    case 'invite':
      return 'signup';
    case 'recovery':
    case 'email_change':
    case 'magiclink':
    case 'reauthentication':
      return actionType;
    default:
      return null;
  }
}

/// `fr-FR`, `fr_FR`, `FR` -> `fr` ; null si la langue n'est pas gérée.
export function normalizeLocale(value: unknown): Locale | null {
  if (typeof value !== 'string') return null;
  const code = value.trim().toLowerCase().split(/[-_]/)[0];
  return (SUPPORTED_LOCALES as readonly string[]).includes(code)
    ? (code as Locale)
    : null;
}

/// Langue de l'email, par ordre de priorité : métadonnée `locale` de
/// l'utilisateur (posée par le site et l'app), paramètre `lang` de l'URL de
/// redirection (posé par le site), sinon l'anglais.
export function resolveLocale(
  userLocale: unknown,
  redirectTo: string | undefined,
): Locale {
  const fromUser = normalizeLocale(userLocale);
  if (fromUser) return fromUser;

  if (redirectTo) {
    try {
      const fromUrl = normalizeLocale(new URL(redirectTo).searchParams.get('lang'));
      if (fromUrl) return fromUrl;
    } catch {
      // redirect_to invalide : on retombe sur la langue par défaut.
    }
  }
  return DEFAULT_LOCALE;
}

interface Copy {
  subject: string;
  heading: string;
  intro: string;
  /// Libellé du bouton (absent pour les emails à code, sans lien).
  button?: string;
  /// Phrase affichée au-dessus du code à 6 chiffres (reauthentication).
  codeIntro?: string;
  validity: string;
  ignore: string;
}

interface LocaleCopy {
  tagline: string;
  greeting: string;
  linkFallback: string;
  contact: string;
  kinds: Record<EmailKind, Copy>;
}

const COPY: Record<Locale, LocaleCopy> = {
  fr: {
    tagline: 'Meshiker – Application de navigation pour la randonnée',
    greeting: 'Bonjour,',
    linkFallback: 'Si le bouton ne fonctionne pas, copiez ce lien dans votre navigateur :',
    contact: 'Une question ? Écrivez-nous à contact@meshiker.com',
    kinds: {
      signup: {
        subject: 'Confirmez votre adresse email – Meshiker',
        heading: 'Bienvenue sur Meshiker',
        intro:
          "Vous venez de créer un compte Meshiker avec cette adresse email. Pour l'activer, confirmez votre adresse en cliquant sur le bouton ci-dessous :",
        button: 'Confirmer mon adresse',
        validity:
          "Ce lien est valable une heure et ne peut être utilisé qu'une fois. Une fois votre adresse confirmée, vous pouvez vous connecter avec votre email et votre mot de passe, sur le site comme dans l'application.",
        ignore:
          "Si vous n'êtes pas à l'origine de cette inscription, ignorez simplement ce message : aucun compte ne sera activé.",
      },
      recovery: {
        subject: 'Réinitialisation de votre mot de passe – Meshiker',
        heading: 'Réinitialisation du mot de passe',
        intro:
          'Nous avons reçu une demande de réinitialisation du mot de passe de votre compte Meshiker. Pour choisir un nouveau mot de passe, cliquez sur le bouton ci-dessous :',
        button: 'Choisir un nouveau mot de passe',
        validity: "Ce lien est valable une heure et ne peut être utilisé qu'une fois.",
        ignore:
          "Si vous n'avez pas demandé cette réinitialisation, ignorez simplement ce message : votre mot de passe actuel reste inchangé.",
      },
      email_change: {
        subject: "Confirmez votre nouvelle adresse email – Meshiker",
        heading: "Confirmation de l'adresse email",
        intro:
          "Une demande d'ajout ou de changement d'adresse email a été faite sur votre compte Meshiker. Pour la confirmer, cliquez sur le bouton ci-dessous :",
        button: 'Confirmer cette adresse',
        validity: "Ce lien est valable une heure et ne peut être utilisé qu'une fois.",
        ignore:
          "Si vous n'êtes pas à l'origine de cette demande, ignorez simplement ce message : votre compte reste inchangé.",
      },
      magiclink: {
        subject: 'Votre lien de connexion – Meshiker',
        heading: 'Connexion à Meshiker',
        intro: 'Cliquez sur le bouton ci-dessous pour vous connecter à votre compte Meshiker :',
        button: 'Me connecter',
        validity: "Ce lien est valable une heure et ne peut être utilisé qu'une fois.",
        ignore:
          "Si vous n'avez pas demandé ce lien, ignorez simplement ce message.",
      },
      reauthentication: {
        subject: 'Votre code de confirmation – Meshiker',
        heading: 'Code de confirmation',
        intro: 'Pour confirmer cette opération sur votre compte Meshiker, saisissez le code suivant :',
        codeIntro: 'Votre code :',
        validity: 'Ce code est valable quelques minutes.',
        ignore:
          "Si vous n'êtes pas à l'origine de cette demande, ignorez ce message et pensez à changer votre mot de passe.",
      },
    },
  },
  en: {
    tagline: 'Meshiker – Hiking navigation app',
    greeting: 'Hello,',
    linkFallback: "If the button doesn't work, copy this link into your browser:",
    contact: 'Questions? Write to us at contact@meshiker.com',
    kinds: {
      signup: {
        subject: 'Confirm your email address – Meshiker',
        heading: 'Welcome to Meshiker',
        intro:
          'You just created a Meshiker account with this email address. To activate it, confirm your address by clicking the button below:',
        button: 'Confirm my address',
        validity:
          'This link is valid for one hour and can only be used once. Once your address is confirmed, you can sign in with your email and password, on the website and in the app.',
        ignore:
          "If you didn't sign up, simply ignore this message: no account will be activated.",
      },
      recovery: {
        subject: 'Reset your password – Meshiker',
        heading: 'Password reset',
        intro:
          'We received a request to reset the password of your Meshiker account. To choose a new password, click the button below:',
        button: 'Choose a new password',
        validity: 'This link is valid for one hour and can only be used once.',
        ignore:
          "If you didn't request this reset, simply ignore this message: your current password stays unchanged.",
      },
      email_change: {
        subject: 'Confirm your new email address – Meshiker',
        heading: 'Email address confirmation',
        intro:
          'A request to add or change the email address of your Meshiker account was made. To confirm it, click the button below:',
        button: 'Confirm this address',
        validity: 'This link is valid for one hour and can only be used once.',
        ignore:
          "If you didn't make this request, simply ignore this message: your account stays unchanged.",
      },
      magiclink: {
        subject: 'Your sign-in link – Meshiker',
        heading: 'Sign in to Meshiker',
        intro: 'Click the button below to sign in to your Meshiker account:',
        button: 'Sign me in',
        validity: 'This link is valid for one hour and can only be used once.',
        ignore: "If you didn't request this link, simply ignore this message.",
      },
      reauthentication: {
        subject: 'Your confirmation code – Meshiker',
        heading: 'Confirmation code',
        intro: 'To confirm this operation on your Meshiker account, enter the following code:',
        codeIntro: 'Your code:',
        validity: 'This code is valid for a few minutes.',
        ignore:
          "If you didn't make this request, ignore this message and consider changing your password.",
      },
    },
  },
};

const HTML_ESCAPES: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => HTML_ESCAPES[c]);
}

export interface RenderedEmail {
  subject: string;
  html: string;
  text: string;
}

/// Génère sujet + HTML + texte brut (le texte brut améliore la
/// délivrabilité). [url] pour les emails à lien, [code] pour `reauthentication`.
export function renderEmail(args: {
  kind: EmailKind;
  locale: Locale;
  url?: string;
  code?: string;
}): RenderedEmail {
  const lang = COPY[args.locale];
  const copy = lang.kinds[args.kind];

  const isCode = args.kind === 'reauthentication';
  if (isCode && !args.code) throw new Error('renderEmail: code requis pour reauthentication');
  if (!isCode && !args.url) throw new Error(`renderEmail: url requise pour ${args.kind}`);

  const action = isCode
    ? `<p style="margin: 24px 0; font-size: 28px; letter-spacing: 6px; font-weight: bold; color: #047857;">${escapeHtml(args.code!)}</p>`
    : `<p style="margin: 24px 0;"><a href="${escapeHtml(args.url!)}" style="background: #047857; color: #ffffff; padding: 12px 20px; border-radius: 8px; text-decoration: none; font-weight: bold; display: inline-block;">${escapeHtml(copy.button!)}</a></p>` +
      `<p style="font-size: 12px; color: #6b7280; word-break: break-all;">${escapeHtml(lang.linkFallback)}<br>${escapeHtml(args.url!)}</p>`;

  const html = `<!doctype html>
<html lang="${args.locale}">
<body style="margin: 0; padding: 0;">
<div style="font-family: Arial, Helvetica, sans-serif; max-width: 520px; margin: 0 auto; padding: 24px; color: #1f2937; line-height: 1.5;">
  <h2 style="margin: 0 0 16px; color: #047857;">${escapeHtml(copy.heading)}</h2>
  <p>${escapeHtml(lang.greeting)}</p>
  <p>${escapeHtml(copy.intro)}</p>
  ${action}
  <p style="font-size: 14px; color: #4b5563;">${escapeHtml(copy.validity)}</p>
  <p style="font-size: 14px; color: #4b5563;">${escapeHtml(copy.ignore)}</p>
  <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 24px 0;">
  <p style="font-size: 12px; color: #6b7280;">${escapeHtml(lang.tagline)}<br>${escapeHtml(lang.contact)}</p>
</div>
</body>
</html>`;

  const text = [
    copy.heading,
    '',
    lang.greeting,
    '',
    copy.intro,
    '',
    isCode ? `${copy.codeIntro} ${args.code}` : args.url,
    '',
    copy.validity,
    copy.ignore,
    '',
    '--',
    lang.tagline,
    lang.contact,
  ].join('\n');

  return { subject: copy.subject, html, text };
}
