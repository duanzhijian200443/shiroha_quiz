#ifndef SHIROHA_L1_CRYPTO_FAKE_WIN32_H_
#define SHIROHA_L1_CRYPTO_FAKE_WIN32_H_
// SDK prerequisite order is significant; do not sort these includes.
// clang-format off
#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>
// clang-format on
// Forced include ONLY on the offline wrapper test. SDK declarations are read
// first; every operational entry below is replaced by an in-memory Fake.
#define BCryptOpenAlgorithmProvider fake_BCryptOpenAlgorithmProvider
#define BCryptCloseAlgorithmProvider fake_BCryptCloseAlgorithmProvider
#define BCryptGenerateKeyPair fake_BCryptGenerateKeyPair
#define BCryptFinalizeKeyPair fake_BCryptFinalizeKeyPair
#define BCryptExportKey fake_BCryptExportKey
#define BCryptImportKeyPair fake_BCryptImportKeyPair
#define BCryptSignHash fake_BCryptSignHash
#define BCryptVerifySignature fake_BCryptVerifySignature
#define BCryptDestroyKey fake_BCryptDestroyKey
#define CertCreateCertificateContext fake_CertCreateCertificateContext
#define CertFreeCertificateContext fake_CertFreeCertificateContext
#define CryptDecodeObjectEx fake_CryptDecodeObjectEx
#define LocalFree fake_LocalFree
#define CertVerifyTimeValidity fake_CertVerifyTimeValidity
NTSTATUS fake_BCryptOpenAlgorithmProvider(BCRYPT_ALG_HANDLE *, LPCWSTR, LPCWSTR,
                                          ULONG);
NTSTATUS fake_BCryptCloseAlgorithmProvider(BCRYPT_ALG_HANDLE, ULONG);
NTSTATUS fake_BCryptGenerateKeyPair(BCRYPT_ALG_HANDLE, BCRYPT_KEY_HANDLE *,
                                    ULONG, ULONG);
NTSTATUS fake_BCryptFinalizeKeyPair(BCRYPT_KEY_HANDLE, ULONG);
NTSTATUS fake_BCryptExportKey(BCRYPT_KEY_HANDLE, BCRYPT_KEY_HANDLE, LPCWSTR,
                              PUCHAR, ULONG, ULONG *, ULONG);
NTSTATUS fake_BCryptImportKeyPair(BCRYPT_ALG_HANDLE, BCRYPT_KEY_HANDLE, LPCWSTR,
                                  BCRYPT_KEY_HANDLE *, PUCHAR, ULONG, ULONG);
NTSTATUS fake_BCryptSignHash(BCRYPT_KEY_HANDLE, void *, PUCHAR, ULONG, PUCHAR,
                             ULONG, ULONG *, ULONG);
NTSTATUS fake_BCryptVerifySignature(BCRYPT_KEY_HANDLE, void *, PUCHAR, ULONG,
                                    PUCHAR, ULONG, ULONG);
NTSTATUS fake_BCryptDestroyKey(BCRYPT_KEY_HANDLE);
PCCERT_CONTEXT fake_CertCreateCertificateContext(DWORD, const BYTE *, DWORD);
BOOL fake_CertFreeCertificateContext(PCCERT_CONTEXT);
BOOL fake_CryptDecodeObjectEx(DWORD, LPCSTR, const BYTE *, DWORD, DWORD,
                              PCRYPT_DECODE_PARA, void *, DWORD *);
HLOCAL fake_LocalFree(HLOCAL);
LONG fake_CertVerifyTimeValidity(LPFILETIME, PCERT_INFO);
#endif
