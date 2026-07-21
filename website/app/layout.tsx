import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { headers } from "next/headers";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host =
    requestHeaders.get("x-forwarded-host") ??
    requestHeaders.get("host") ??
    "localhost:3000";
  const protocol =
    requestHeaders.get("x-forwarded-proto") ??
    (host.startsWith("localhost") ? "http" : "https");
  const baseUrl = new URL(`${protocol}://${host}`);
  const socialImage = new URL("/og.png", baseUrl).toString();

  return {
    metadataBase: baseUrl,
    title: "EQ for Mac — System-wide equalizer for macOS",
    description:
      "Shape every sound on your Mac with a native 15-band system-wide equalizer, offline headphone curves, and no virtual audio driver.",
    icons: {
      icon: "/app-icon.png",
      apple: "/app-icon.png",
    },
    openGraph: {
      title: "EQ for Mac — Make your Mac sound like yours.",
      description:
        "A native, system-wide equalizer for macOS with 6,800+ offline headphone curves.",
      type: "website",
      url: baseUrl,
      images: [
        {
          url: socialImage,
          width: 1721,
          height: 914,
          alt: "EQ for Mac — Make your Mac sound like yours.",
        },
      ],
    },
    twitter: {
      card: "summary_large_image",
      title: "EQ for Mac — Make your Mac sound like yours.",
      description:
        "A native, system-wide equalizer for macOS with 6,800+ offline headphone curves.",
      images: [socialImage],
    },
  };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script
          dangerouslySetInnerHTML={{
            __html: `(function(){try{var saved=localStorage.getItem("eq-theme");var theme=saved==="dark"||saved==="light"?saved:(window.matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light");document.documentElement.dataset.theme=theme;}catch(e){document.documentElement.dataset.theme="light";}})();`,
          }}
        />
      </head>
      <body className={`${geistSans.variable} ${geistMono.variable}`}>
        {children}
      </body>
    </html>
  );
}
