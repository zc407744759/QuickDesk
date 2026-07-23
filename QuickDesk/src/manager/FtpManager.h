// Copyright 2026 QuickDesk Authors
#ifndef QUICKDESK_MANAGER_FTPMANAGER_H
#define QUICKDESK_MANAGER_FTPMANAGER_H

#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QPointer>
#include <QQueue>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QWebSocket>

namespace quickdesk {

class AuthManager;
class HostManager;
class ServerManager;

class FtpManager : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool hostOnline READ hostOnline NOTIFY hostOnlineChanged)

public:
    explicit FtpManager(ServerManager* serverManager,
                        HostManager* hostManager,
                        AuthManager* authManager,
                        QObject* parent = nullptr);
    ~FtpManager() override;

    bool hostOnline() const { return m_hostSocket && m_hostSocket->state() == QAbstractSocket::ConnectedState; }

    Q_INVOKABLE void startHost();
    Q_INVOKABLE void stopHost();
    Q_INVOKABLE void connectClient(const QString& deviceId,
                                   const QString& signalToken,
                                   const QString& serverUrl);
    Q_INVOKABLE void disconnectClient(const QString& deviceId);

    Q_INVOKABLE QVariantList listLocalDirectory(const QString& path) const;
    Q_INVOKABLE QString defaultLocalDirectory() const;
    Q_INVOKABLE QString parentDirectory(const QString& path) const;
    Q_INVOKABLE QString homeDirectory() const;
    Q_INVOKABLE QString downloadsDirectory() const;

    Q_INVOKABLE void listRemoteDirectory(const QString& deviceId, const QString& path);
    Q_INVOKABLE void uploadFile(const QString& deviceId,
                                const QUrl& localFileUrl,
                                const QString& remoteDirectory);
    Q_INVOKABLE void downloadFile(const QString& deviceId,
                                  const QString& remoteFilePath,
                                  const QString& localDirectory);
    Q_INVOKABLE void makeRemoteDirectory(const QString& deviceId,
                                         const QString& parentPath,
                                         const QString& name);
    Q_INVOKABLE void deleteRemotePath(const QString& deviceId,
                                      const QString& remotePath);

signals:
    void hostOnlineChanged();
    void clientConnected(const QString& deviceId);
    void clientDisconnected(const QString& deviceId);
    void remoteDirectoryListed(const QString& deviceId,
                               const QString& path,
                               const QVariantList& entries);
    void transferProgress(const QString& deviceId,
                          const QString& transferId,
                          const QString& direction,
                          double transferredBytes,
                          double totalBytes);
    void transferComplete(const QString& deviceId,
                          const QString& transferId,
                          const QString& direction,
                          const QString& localPath,
                          const QString& remotePath);
    void errorOccurred(const QString& deviceId,
                       const QString& code,
                       const QString& message);

private slots:
    void onHostTextMessage(const QString& text);

private:
    struct ClientSession {
        QWebSocket* socket = nullptr;
        QString signalToken;
        QString serverUrl;
    };

    struct UploadState {
        QString deviceId;
        QString transferId;
        QString remotePath;
        QFile* file = nullptr;
        qint64 totalBytes = 0;
        qint64 sentBytes = 0;
        QTimer* timer = nullptr;
    };

    struct DownloadState {
        QString deviceId;
        QString transferId;
        QString remotePath;
        QString localPath;
        QFile* file = nullptr;
        qint64 totalBytes = 0;
        qint64 receivedBytes = 0;
    };

    QString httpBaseUrl(const QString& serverUrl = QString()) const;
    QString wsSignalUrl(const QString& serverUrl = QString()) const;
    QString newTransferId() const;
    static QString normalizedLocalPath(const QString& path);
    static QString pathJoin(const QString& directory, const QString& name);
    static QJsonObject entryForFileInfo(const QFileInfo& info);

    void requestHostSignalToken();
    void openHostSocket(const QString& token);
    void sendHost(const QJsonObject& obj);
    void sendClient(const QString& deviceId, const QJsonObject& obj);
    void sendJson(QWebSocket* socket, const QJsonObject& obj);
    ClientSession* clientSession(const QString& deviceId);
    QWebSocket* clientSocket(const QString& deviceId) const;

    void handleHostListRequest(const QJsonObject& msg);
    void handleHostMkdirRequest(const QJsonObject& msg);
    void handleHostDeleteRequest(const QJsonObject& msg);
    void handleHostUploadStart(const QJsonObject& msg);
    void handleHostUploadChunk(const QJsonObject& msg);
    void handleHostUploadEnd(const QJsonObject& msg);
    void handleHostDownloadRequest(const QJsonObject& msg);
    void handleClientMessage(const QString& deviceId, const QJsonObject& msg);

    void pumpUploadChunk(const QString& transferId);

    ServerManager* m_serverManager = nullptr;
    HostManager* m_hostManager = nullptr;
    AuthManager* m_authManager = nullptr;
    QNetworkAccessManager m_network;

    QWebSocket* m_hostSocket = nullptr;
    QHash<QString, ClientSession> m_clients;
    QHash<QString, UploadState> m_uploads;
    QHash<QString, DownloadState> m_downloads;
    QHash<QString, QString> m_downloadTargetDirs;
};

} // namespace quickdesk

#endif // QUICKDESK_MANAGER_FTPMANAGER_H
