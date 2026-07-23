// Copyright 2026 QuickDesk Authors
#include "FtpManager.h"

#include "AuthManager.h"
#include "HostManager.h"
#include "ServerManager.h"
#include "infra/log/log.h"

#include <QDateTime>
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRandomGenerator>
#include <QSettings>
#include <QStandardPaths>
#include <algorithm>

namespace quickdesk {

namespace {
constexpr qint64 kChunkSize = 48 * 1024;
constexpr int kChunkIntervalMs = 1;
constexpr int kMaxHostTokenRetryDelayMs = 30000;
constexpr int kMaxClientReconnectDelayMs = 10000;

bool isFtpType(const QString& type)
{
    return type.startsWith(QStringLiteral("qd_ftp_"));
}

QString problemMessage(const QByteArray& body, const QString& fallback)
{
    const QJsonObject obj = QJsonDocument::fromJson(body).object();
    const QString detail = obj.value(QStringLiteral("detail")).toString();
    if (!detail.isEmpty()) return detail;
    const QString title = obj.value(QStringLiteral("title")).toString();
    return title.isEmpty() ? fallback : title;
}
}

FtpManager::FtpManager(ServerManager* serverManager,
                       HostManager* hostManager,
                       AuthManager* authManager,
                       QObject* parent)
    : QObject(parent)
    , m_serverManager(serverManager)
    , m_hostManager(hostManager)
    , m_authManager(authManager)
{
    if (m_hostManager) {
        connect(m_hostManager, &HostManager::deviceSecretReady,
                this, [this](const QString&) { startHost(); });
        connect(m_hostManager, &HostManager::connectionStatusChanged,
                this, [this]() {
                    if (m_hostManager->isConnected()) startHost();
                    else stopHost();
                });
        QTimer::singleShot(0, this, &FtpManager::startHost);
    }
}

FtpManager::~FtpManager()
{
    stopHost();
    const auto keys = m_clients.keys();
    for (const auto& key : keys) {
        disconnectClient(key);
    }
}

void FtpManager::startHost()
{
    if (!m_hostManager || !m_hostManager->isConnected()
            || m_hostManager->deviceId().isEmpty()
            || m_hostManager->deviceSecret().isEmpty()) {
        LOG_WARN("[FtpManager] startHost skipped: connected={} deviceIdEmpty={} secretEmpty={}",
                 m_hostManager && m_hostManager->isConnected(),
                 !m_hostManager || m_hostManager->deviceId().isEmpty(),
                 !m_hostManager || m_hostManager->deviceSecret().isEmpty());
        return;
    }
    if (hostOnline()) return;
    if (m_hostTokenRequestInFlight) {
        LOG_INFO("[FtpManager] FTP host token request already in flight");
        return;
    }
    LOG_INFO("[FtpManager] starting FTP host channel: device={}",
             m_hostManager->deviceId().toStdString());
    requestHostSignalToken();
}

void FtpManager::stopHost()
{
    if (!m_hostSocket) return;
    auto* socket = m_hostSocket;
    m_hostSocket = nullptr;
    LOG_INFO("[FtpManager] stopping FTP host channel");
    socket->close();
    socket->deleteLater();
    emit hostOnlineChanged();
}

void FtpManager::connectClient(const QString& deviceId,
                               const QString& signalToken,
                               const QString& serverUrl)
{
    if (deviceId.isEmpty() || signalToken.isEmpty()) {
        emit errorOccurred(deviceId, QStringLiteral("AUTH_INVALID"),
                           tr("Missing FTP signal token"));
        return;
    }

    disconnectClient(deviceId);
    LOG_INFO("[FtpManager] connecting FTP client channel: device={} server={}",
             deviceId.toStdString(), serverUrl.toStdString());

    ClientSession session;
    session.signalToken = signalToken;
    session.serverUrl = serverUrl;
    session.socket = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
    m_clients.insert(deviceId, session);

    auto* socket = session.socket;
    connect(socket, &QWebSocket::connected, this, [this, deviceId, socket]() {
        LOG_INFO("[FtpManager] FTP client socket connected: device={}",
                 deviceId.toStdString());
        QJsonObject auth;
        auth[QStringLiteral("type")] = QStringLiteral("auth");
        auth[QStringLiteral("role")] = QStringLiteral("client");
        auth[QStringLiteral("channel")] = QStringLiteral("ftp");
        auth[QStringLiteral("device_id")] = deviceId;
        auth[QStringLiteral("client_id")] = QStringLiteral("ftp_") + QString::number(QCoreApplication::applicationPid());
        auth[QStringLiteral("signal_token")] = m_clients.value(deviceId).signalToken;
        sendJson(socket, auth);
    });
    connect(socket, &QWebSocket::textMessageReceived, this, [this, deviceId](const QString& text) {
        const QJsonObject msg = QJsonDocument::fromJson(text.toUtf8()).object();
        const QString type = msg.value(QStringLiteral("type")).toString();
        if (type == QStringLiteral("auth_ok")) {
            auto* session = clientSession(deviceId);
            if (session) {
                session->authenticated = true;
                session->reconnectCount = 0;
            }
            LOG_INFO("[FtpManager] FTP client auth_ok: device={}",
                     deviceId.toStdString());
            emit clientConnected(deviceId);
            const QString pendingPath = session ? session->pendingListPath : QString();
            if (session) session->pendingListPath.clear();
            listRemoteDirectory(deviceId, pendingPath);
            return;
        }
        if (type == QStringLiteral("error")) {
            if (auto* session = clientSession(deviceId)) {
                session->authenticated = false;
            }
            const QString code = msg.value(QStringLiteral("code")).toString(QStringLiteral("FTP_SIGNAL_ERROR"));
            QString message = msg.value(QStringLiteral("message")).toString();
            if (message.isEmpty()) message = msg.value(QStringLiteral("detail")).toString();
            if (message.isEmpty() && code == QStringLiteral("PEER_DISCONNECTED")) {
                message = tr("Remote file channel is unavailable. Install the latest QuickDesk on the remote device and redeploy the signaling server if needed.");
            }
            if (message.isEmpty()) message = tr("Remote file channel error");
            LOG_ERROR("[FtpManager] FTP client signal error: device={} code={} message={}",
                      deviceId.toStdString(), code.toStdString(), message.toStdString());
            emit errorOccurred(deviceId, code, message);
            scheduleClientReconnect(deviceId, code);
            return;
        }
        if (isFtpType(type)) {
            handleClientMessage(deviceId, msg);
        }
    });
    connect(socket, &QWebSocket::disconnected, this, [this, deviceId, socket]() {
        auto* session = clientSession(deviceId);
        if (session && session->socket != socket) return;
        if (session) session->authenticated = false;
        LOG_WARN("[FtpManager] FTP client disconnected: device={}",
                 deviceId.toStdString());
        emit clientDisconnected(deviceId);
        scheduleClientReconnect(deviceId, QStringLiteral("socket disconnected"));
    });
    connect(socket, &QWebSocket::errorOccurred, this, [this, deviceId, socket](QAbstractSocket::SocketError) {
        auto* session = clientSession(deviceId);
        if (session && session->socket != socket) return;
        LOG_ERROR("[FtpManager] FTP client socket error: device={} error={}",
                  deviceId.toStdString(), socket->errorString().toStdString());
        emit errorOccurred(deviceId, QStringLiteral("FTP_SOCKET_ERROR"), socket->errorString());
    });

    socket->open(QUrl(wsSignalUrl(serverUrl)));
}

void FtpManager::disconnectClient(const QString& deviceId)
{
    auto it = m_clients.find(deviceId);
    if (it == m_clients.end()) return;
    if (it->socket) {
        LOG_INFO("[FtpManager] disconnecting FTP client channel: device={}",
                 deviceId.toStdString());
        it->socket->close();
        it->socket->deleteLater();
    }
    m_clients.erase(it);
}

QVariantList FtpManager::listLocalDirectory(const QString& path) const
{
    const QString dirPath = path.isEmpty() ? defaultLocalDirectory() : path;
    QDir dir(dirPath);
    QVariantList out;
    const QFileInfoList entries = dir.entryInfoList(
        QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Readable,
        QDir::DirsFirst | QDir::Name | QDir::IgnoreCase);
    for (const QFileInfo& info : entries) {
        out.append(entryForFileInfo(info).toVariantMap());
    }
    return out;
}

QString FtpManager::defaultLocalDirectory() const
{
    QString path = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    return path.isEmpty() ? QDir::homePath() : path;
}

QString FtpManager::lastLocalDirectory() const
{
    const QString saved = QSettings().value(QStringLiteral("ftp/lastLocalDirectory")).toString();
    return saved.isEmpty() ? defaultLocalDirectory() : saved;
}

QString FtpManager::lastRemoteDirectory(const QString& deviceId) const
{
    if (deviceId.isEmpty()) return QString();
    return QSettings().value(QStringLiteral("ftp/lastRemoteDirectory/%1").arg(deviceId)).toString();
}

void FtpManager::saveLastLocalDirectory(const QString& path)
{
    if (path.isEmpty()) return;
    QSettings().setValue(QStringLiteral("ftp/lastLocalDirectory"), path);
}

void FtpManager::saveLastRemoteDirectory(const QString& deviceId, const QString& path)
{
    if (deviceId.isEmpty() || path.isEmpty()) return;
    QSettings().setValue(QStringLiteral("ftp/lastRemoteDirectory/%1").arg(deviceId), path);
}

QString FtpManager::parentDirectory(const QString& path) const
{
    QDir dir(path.isEmpty() ? defaultLocalDirectory() : path);
    dir.cdUp();
    return dir.absolutePath();
}

QString FtpManager::homeDirectory() const
{
    return QDir::homePath();
}

QString FtpManager::downloadsDirectory() const
{
    return defaultLocalDirectory();
}

void FtpManager::listRemoteDirectory(const QString& deviceId, const QString& path)
{
    auto* session = clientSession(deviceId);
    if (!session || !session->socket || !session->authenticated
            || session->socket->state() != QAbstractSocket::ConnectedState) {
        if (session) session->pendingListPath = path;
        LOG_WARN("[FtpManager] queue remote list until FTP client is ready: device={} path={} hasSession={} state={}",
                 deviceId.toStdString(), path.toStdString(), session != nullptr,
                 session && session->socket ? static_cast<int>(session->socket->state()) : -1);
        scheduleClientReconnect(deviceId, QStringLiteral("list requested while not ready"));
        return;
    }
    QJsonObject msg;
    msg[QStringLiteral("type")] = QStringLiteral("qd_ftp_list_req");
    msg[QStringLiteral("path")] = path;
    LOG_INFO("[FtpManager] send remote list request: device={} path={}",
             deviceId.toStdString(), path.toStdString());
    sendClient(deviceId, msg);
}

void FtpManager::uploadFile(const QString& deviceId,
                            const QUrl& localFileUrl,
                            const QString& remoteDirectory)
{
    if (!isClientReady(deviceId)) {
        emit errorOccurred(deviceId, QStringLiteral("FTP_NOT_READY"),
                           tr("Remote file channel is reconnecting. Please try again in a moment."));
        scheduleClientReconnect(deviceId, QStringLiteral("upload requested while not ready"));
        return;
    }
    if (!localFileUrl.isLocalFile()) {
        emit errorOccurred(deviceId, QStringLiteral("LOCAL_FILE_INVALID"),
                           tr("Only local files can be uploaded"));
        return;
    }
    QFileInfo info(localFileUrl.toLocalFile());
    if (!info.isFile() || !info.isReadable()) {
        emit errorOccurred(deviceId, QStringLiteral("LOCAL_FILE_INVALID"),
                           tr("Local file is not readable"));
        return;
    }

    auto* file = new QFile(info.absoluteFilePath(), this);
    if (!file->open(QIODevice::ReadOnly)) {
        file->deleteLater();
        emit errorOccurred(deviceId, QStringLiteral("LOCAL_FILE_OPEN_FAILED"),
                           tr("Failed to open local file"));
        return;
    }

    const QString transferId = newTransferId();
    UploadState state;
    state.deviceId = deviceId;
    state.transferId = transferId;
    state.remotePath = pathJoin(remoteDirectory, info.fileName());
    state.file = file;
    state.totalBytes = info.size();
    state.timer = new QTimer(this);
    m_uploads.insert(transferId, state);

    QJsonObject start;
    start[QStringLiteral("type")] = QStringLiteral("qd_ftp_upload_start");
    start[QStringLiteral("transfer_id")] = transferId;
    start[QStringLiteral("remote_path")] = state.remotePath;
    start[QStringLiteral("filename")] = info.fileName();
    start[QStringLiteral("size")] = static_cast<double>(state.totalBytes);
    sendClient(deviceId, start);

    connect(state.timer, &QTimer::timeout, this, [this, transferId]() {
        pumpUploadChunk(transferId);
    });
    state.timer->start(kChunkIntervalMs);
    m_uploads[transferId].timer = state.timer;
}

void FtpManager::downloadFile(const QString& deviceId,
                              const QString& remoteFilePath,
                              const QString& localDirectory)
{
    if (!isClientReady(deviceId)) {
        emit errorOccurred(deviceId, QStringLiteral("FTP_NOT_READY"),
                           tr("Remote file channel is reconnecting. Please try again in a moment."));
        scheduleClientReconnect(deviceId, QStringLiteral("download requested while not ready"));
        return;
    }
    if (remoteFilePath.isEmpty()) return;
    QDir dir(localDirectory.isEmpty() ? defaultLocalDirectory() : localDirectory);
    if (!dir.exists() && !dir.mkpath(QStringLiteral("."))) {
        emit errorOccurred(deviceId, QStringLiteral("LOCAL_DIR_INVALID"),
                           tr("Failed to create local directory"));
        return;
    }
    const QString transferId = newTransferId();
    QJsonObject req;
    req[QStringLiteral("type")] = QStringLiteral("qd_ftp_download_req");
    req[QStringLiteral("transfer_id")] = transferId;
    req[QStringLiteral("remote_path")] = remoteFilePath;
    m_downloadTargetDirs.insert(transferId, dir.absolutePath());
    LOG_INFO("[FtpManager] request download: device={} transfer={} remote={} localDir={}",
             deviceId.toStdString(), transferId.toStdString(),
             remoteFilePath.toStdString(), dir.absolutePath().toStdString());
    sendClient(deviceId, req);
}

void FtpManager::makeRemoteDirectory(const QString& deviceId,
                                     const QString& parentPath,
                                     const QString& name)
{
    if (!isClientReady(deviceId)) {
        emit errorOccurred(deviceId, QStringLiteral("FTP_NOT_READY"),
                           tr("Remote file channel is reconnecting. Please try again in a moment."));
        scheduleClientReconnect(deviceId, QStringLiteral("mkdir requested while not ready"));
        return;
    }
    QJsonObject req;
    req[QStringLiteral("type")] = QStringLiteral("qd_ftp_mkdir_req");
    req[QStringLiteral("path")] = pathJoin(parentPath, name);
    req[QStringLiteral("parent_path")] = parentPath;
    sendClient(deviceId, req);
}

void FtpManager::deleteRemotePath(const QString& deviceId, const QString& remotePath)
{
    if (!isClientReady(deviceId)) {
        emit errorOccurred(deviceId, QStringLiteral("FTP_NOT_READY"),
                           tr("Remote file channel is reconnecting. Please try again in a moment."));
        scheduleClientReconnect(deviceId, QStringLiteral("delete requested while not ready"));
        return;
    }
    QJsonObject req;
    req[QStringLiteral("type")] = QStringLiteral("qd_ftp_delete_req");
    req[QStringLiteral("path")] = remotePath;
    sendClient(deviceId, req);
}

QString FtpManager::httpBaseUrl(const QString& serverUrl) const
{
    QString url = serverUrl.isEmpty() && m_serverManager ? m_serverManager->serverUrl() : serverUrl;
    url.replace(QStringLiteral("ws://"), QStringLiteral("http://"));
    url.replace(QStringLiteral("wss://"), QStringLiteral("https://"));
    if (!url.endsWith(QLatin1Char('/'))) url += QLatin1Char('/');
    return url;
}

QString FtpManager::wsSignalUrl(const QString& serverUrl) const
{
    QString url = serverUrl.isEmpty() && m_serverManager ? m_serverManager->serverUrl() : serverUrl;
    if (!url.endsWith(QLatin1Char('/'))) url += QLatin1Char('/');
    return url + QStringLiteral("v1/realtime/signal");
}

QString FtpManager::newTransferId() const
{
    return QStringLiteral("ftp_%1_%2")
        .arg(QDateTime::currentMSecsSinceEpoch())
        .arg(QRandomGenerator::global()->generate(), 0, 16);
}

QString FtpManager::normalizedLocalPath(const QString& path)
{
    QFileInfo info(path);
    QString out = info.canonicalFilePath();
    return out.isEmpty() ? info.absoluteFilePath() : out;
}

QString FtpManager::pathJoin(const QString& directory, const QString& name)
{
    if (directory.isEmpty()) return name;
    QDir dir(directory);
    return QDir::cleanPath(dir.filePath(name));
}

QJsonObject FtpManager::entryForFileInfo(const QFileInfo& info)
{
    QJsonObject obj;
    obj[QStringLiteral("name")] = info.fileName();
    obj[QStringLiteral("path")] = normalizedLocalPath(info.absoluteFilePath());
    obj[QStringLiteral("isDir")] = info.isDir();
    obj[QStringLiteral("size")] = static_cast<double>(info.isDir() ? 0 : info.size());
    obj[QStringLiteral("modified")] = info.lastModified().toString(Qt::ISODate);
    return obj;
}

void FtpManager::requestHostSignalToken()
{
    if (!m_hostManager || !m_authManager) return;
    if (!m_hostManager->isConnected()
            || m_hostManager->deviceId().isEmpty()
            || m_hostManager->deviceSecret().isEmpty()) {
        LOG_WARN("[FtpManager] skip FTP host token request: connected={} deviceIdEmpty={} secretEmpty={}",
                 m_hostManager->isConnected(),
                 m_hostManager->deviceId().isEmpty(),
                 m_hostManager->deviceSecret().isEmpty());
        return;
    }
    if (m_hostTokenRequestInFlight) return;
    m_hostTokenRequestInFlight = true;
    LOG_INFO("[FtpManager] requesting FTP host signal token: device={}",
             m_hostManager->deviceId().toStdString());
    QUrl url(httpBaseUrl() + QStringLiteral("v1/devices/")
             + m_hostManager->deviceId()
             + QStringLiteral("/signal-tokens"));
    QNetworkRequest req(url);
    const auto headers = m_authManager->publicHeaders();
    for (const auto& h : headers) {
        req.setRawHeader(h.first.toUtf8(), h.second.toUtf8());
    }
    req.setRawHeader("Authorization",
                     (QStringLiteral("Bearer ") + m_hostManager->deviceSecret()).toUtf8());
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    auto* reply = m_network.post(req, QByteArray("{}"));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        m_hostTokenRequestInFlight = false;
        const QByteArray body = reply->readAll();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError || status < 200 || status >= 300) {
            const QString msg = problemMessage(body, reply->errorString());
            LOG_ERROR("[FtpManager] FTP host signal token failed: http={} error={} detail={}",
                      status, reply->errorString().toStdString(), msg.toStdString());
            emit errorOccurred(QString(), QStringLiteral("HOST_TOKEN_FAILED"),
                               msg);
            reply->deleteLater();
            scheduleHostSignalTokenRetry(msg);
            return;
        }
        const QString token = QJsonDocument::fromJson(body).object()
            .value(QStringLiteral("signal_token")).toString();
        reply->deleteLater();
        if (token.isEmpty()) {
            LOG_ERROR("[FtpManager] FTP host signal token empty");
            emit errorOccurred(QString(), QStringLiteral("HOST_TOKEN_EMPTY"),
                               tr("Server returned an empty FTP host token"));
            scheduleHostSignalTokenRetry(QStringLiteral("empty token"));
            return;
        }
        m_hostTokenRetryCount = 0;
        openHostSocket(token);
    });
}

void FtpManager::scheduleHostSignalTokenRetry(const QString& reason)
{
    if (!m_hostManager || !m_hostManager->isConnected()) return;
    const int delay = std::min(kMaxHostTokenRetryDelayMs,
                               1000 * (1 << std::min(m_hostTokenRetryCount, 5)));
    ++m_hostTokenRetryCount;
    LOG_WARN("[FtpManager] scheduling FTP host token retry: delayMs={} reason={}",
             delay, reason.toStdString());
    QTimer::singleShot(delay, this, [this]() {
        if (!hostOnline()) startHost();
    });
}

void FtpManager::openHostSocket(const QString& token)
{
    stopHost();
    m_hostSocket = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
    connect(m_hostSocket, &QWebSocket::connected, this, [this, token]() {
        LOG_INFO("[FtpManager] FTP host socket connected; sending auth");
        QJsonObject auth;
        auth[QStringLiteral("type")] = QStringLiteral("auth");
        auth[QStringLiteral("role")] = QStringLiteral("host");
        auth[QStringLiteral("channel")] = QStringLiteral("ftp");
        auth[QStringLiteral("device_id")] = m_hostManager->deviceId();
        auth[QStringLiteral("signal_token")] = token;
        sendJson(m_hostSocket, auth);
    });
    connect(m_hostSocket, &QWebSocket::textMessageReceived,
            this, &FtpManager::onHostTextMessage);
    connect(m_hostSocket, &QWebSocket::disconnected, this, [this]() {
        LOG_WARN("[FtpManager] FTP host socket disconnected");
        emit hostOnlineChanged();
        if (m_hostManager && m_hostManager->isConnected()) {
            scheduleHostSignalTokenRetry(QStringLiteral("host socket disconnected"));
        }
    });
    connect(m_hostSocket, &QWebSocket::errorOccurred, this,
            [this](QAbstractSocket::SocketError) {
                if (m_hostSocket) {
                    LOG_ERROR("[FtpManager] FTP host socket error: {}",
                              m_hostSocket->errorString().toStdString());
                    emit errorOccurred(QString(), QStringLiteral("FTP_HOST_SOCKET_ERROR"),
                                       m_hostSocket->errorString());
                }
            });
    m_hostSocket->open(QUrl(wsSignalUrl()));
}

void FtpManager::sendHost(const QJsonObject& obj)
{
    sendJson(m_hostSocket, obj);
}

void FtpManager::sendClient(const QString& deviceId, const QJsonObject& obj)
{
    sendJson(clientSocket(deviceId), obj);
}

void FtpManager::sendJson(QWebSocket* socket, const QJsonObject& obj)
{
    if (!socket || socket->state() != QAbstractSocket::ConnectedState) {
        LOG_WARN("[FtpManager] drop message because socket is not connected: type={} state={}",
                 obj.value(QStringLiteral("type")).toString().toStdString(),
                 socket ? static_cast<int>(socket->state()) : -1);
        return;
    }
    socket->sendTextMessage(QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact)));
}

bool FtpManager::isClientReady(const QString& deviceId) const
{
    auto it = m_clients.find(deviceId);
    return it != m_clients.end()
        && it->authenticated
        && it->socket
        && it->socket->state() == QAbstractSocket::ConnectedState;
}

void FtpManager::scheduleClientReconnect(const QString& deviceId, const QString& reason)
{
    auto* session = clientSession(deviceId);
    if (!session || session->signalToken.isEmpty()) return;
    if (session->socket && session->socket->state() == QAbstractSocket::ConnectedState
            && session->authenticated) {
        return;
    }

    const QString signalToken = session->signalToken;
    const QString serverUrl = session->serverUrl;
    const QString pendingListPath = session->pendingListPath;
    const int retryIndex = session->reconnectCount;
    session->reconnectCount += 1;
    const int delay = std::min(kMaxClientReconnectDelayMs,
                               1000 * (1 << std::min(retryIndex, 3)));
    LOG_WARN("[FtpManager] scheduling FTP client reconnect: device={} delayMs={} reason={}",
             deviceId.toStdString(), delay, reason.toStdString());

    QTimer::singleShot(delay, this, [this, deviceId, signalToken, serverUrl, pendingListPath]() {
        auto* current = clientSession(deviceId);
        if (!current) return;
        if (current->socket && current->socket->state() == QAbstractSocket::ConnectedState
                && current->authenticated) {
            return;
        }
        connectClient(deviceId, signalToken, serverUrl);
        auto* next = clientSession(deviceId);
        if (next && !pendingListPath.isNull()) {
            next->pendingListPath = pendingListPath;
        }
    });
}

FtpManager::ClientSession* FtpManager::clientSession(const QString& deviceId)
{
    auto it = m_clients.find(deviceId);
    return it == m_clients.end() ? nullptr : &(*it);
}

QWebSocket* FtpManager::clientSocket(const QString& deviceId) const
{
    auto it = m_clients.find(deviceId);
    return it == m_clients.end() ? nullptr : it->socket;
}

void FtpManager::onHostTextMessage(const QString& text)
{
    const QJsonObject msg = QJsonDocument::fromJson(text.toUtf8()).object();
    const QString type = msg.value(QStringLiteral("type")).toString();
    if (type == QStringLiteral("auth_ok")) {
        LOG_INFO("[FtpManager] FTP host auth_ok");
        emit hostOnlineChanged();
    } else if (type == QStringLiteral("qd_ftp_list_req")) {
        handleHostListRequest(msg);
    } else if (type == QStringLiteral("qd_ftp_mkdir_req")) {
        handleHostMkdirRequest(msg);
    } else if (type == QStringLiteral("qd_ftp_delete_req")) {
        handleHostDeleteRequest(msg);
    } else if (type == QStringLiteral("qd_ftp_upload_start")) {
        handleHostUploadStart(msg);
    } else if (type == QStringLiteral("qd_ftp_upload_chunk")) {
        handleHostUploadChunk(msg);
    } else if (type == QStringLiteral("qd_ftp_upload_end")) {
        handleHostUploadEnd(msg);
    } else if (type == QStringLiteral("qd_ftp_download_req")) {
        handleHostDownloadRequest(msg);
    }
}

void FtpManager::handleHostListRequest(const QJsonObject& msg)
{
    const QString clientId = msg.value(QStringLiteral("client_id")).toString();
    QString path = msg.value(QStringLiteral("path")).toString();
    if (path.isEmpty()) path = QDir::homePath();
    QDir dir(path);
    if (!dir.exists()) {
        LOG_WARN("[FtpManager] host list path does not exist, falling back home: path={}",
                 path.toStdString());
        dir = QDir(QDir::homePath());
    }
    QJsonArray arr;
    const QFileInfoList entries = dir.entryInfoList(
        QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Readable,
        QDir::DirsFirst | QDir::Name | QDir::IgnoreCase);
    for (const QFileInfo& info : entries) arr.append(entryForFileInfo(info));
    LOG_INFO("[FtpManager] host list response: path={} entries={}",
             dir.absolutePath().toStdString(), entries.size());
    QJsonObject res;
    res[QStringLiteral("type")] = QStringLiteral("qd_ftp_list_res");
    res[QStringLiteral("client_id")] = clientId;
    res[QStringLiteral("path")] = dir.absolutePath();
    res[QStringLiteral("entries")] = arr;
    sendHost(res);
}

void FtpManager::handleHostMkdirRequest(const QJsonObject& msg)
{
    const QString path = msg.value(QStringLiteral("path")).toString();
    const QString parent = msg.value(QStringLiteral("parent_path")).toString();
    QDir().mkpath(path);
    QJsonObject req;
    req[QStringLiteral("type")] = QStringLiteral("qd_ftp_list_req");
    req[QStringLiteral("client_id")] = msg.value(QStringLiteral("client_id")).toString();
    req[QStringLiteral("path")] = parent;
    handleHostListRequest(req);
}

void FtpManager::handleHostDeleteRequest(const QJsonObject& msg)
{
    const QString path = msg.value(QStringLiteral("path")).toString();
    QFileInfo info(path);
    bool ok = info.isDir() ? QDir(path).removeRecursively() : QFile::remove(path);
    QJsonObject res;
    res[QStringLiteral("type")] = ok ? QStringLiteral("qd_ftp_delete_res") : QStringLiteral("qd_ftp_error");
    res[QStringLiteral("client_id")] = msg.value(QStringLiteral("client_id")).toString();
    res[QStringLiteral("path")] = path;
    if (!ok) res[QStringLiteral("message")] = tr("Failed to delete remote path");
    sendHost(res);
}

void FtpManager::handleHostUploadStart(const QJsonObject& msg)
{
    const QString transferId = msg.value(QStringLiteral("transfer_id")).toString();
    const QString path = msg.value(QStringLiteral("remote_path")).toString();
    auto* file = new QFile(path, this);
    QDir().mkpath(QFileInfo(path).absolutePath());
    if (!file->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        QJsonObject err;
        err[QStringLiteral("type")] = QStringLiteral("qd_ftp_error");
        err[QStringLiteral("client_id")] = msg.value(QStringLiteral("client_id")).toString();
        err[QStringLiteral("transfer_id")] = transferId;
        err[QStringLiteral("message")] = tr("Failed to create remote file");
        sendHost(err);
        file->deleteLater();
        return;
    }
    DownloadState state;
    state.deviceId = msg.value(QStringLiteral("client_id")).toString();
    state.transferId = transferId;
    state.remotePath = path;
    state.file = file;
    state.totalBytes = static_cast<qint64>(msg.value(QStringLiteral("size")).toDouble());
    m_downloads.insert(transferId, state);
}

void FtpManager::handleHostUploadChunk(const QJsonObject& msg)
{
    const QString transferId = msg.value(QStringLiteral("transfer_id")).toString();
    auto it = m_downloads.find(transferId);
    if (it == m_downloads.end() || !it->file) return;
    const QByteArray data = QByteArray::fromBase64(msg.value(QStringLiteral("data")).toString().toLatin1());
    it->file->write(data);
    it->receivedBytes += data.size();
}

void FtpManager::handleHostUploadEnd(const QJsonObject& msg)
{
    const QString transferId = msg.value(QStringLiteral("transfer_id")).toString();
    auto it = m_downloads.find(transferId);
    if (it == m_downloads.end()) return;
    if (it->file) {
        it->file->close();
        it->file->deleteLater();
    }
    QJsonObject done;
    done[QStringLiteral("type")] = QStringLiteral("qd_ftp_upload_done");
    done[QStringLiteral("client_id")] = msg.value(QStringLiteral("client_id")).toString();
    done[QStringLiteral("transfer_id")] = transferId;
    done[QStringLiteral("remote_path")] = it->remotePath;
    sendHost(done);
    m_downloads.erase(it);
}

void FtpManager::handleHostDownloadRequest(const QJsonObject& msg)
{
    const QString clientId = msg.value(QStringLiteral("client_id")).toString();
    const QString transferId = msg.value(QStringLiteral("transfer_id")).toString();
    const QString path = msg.value(QStringLiteral("remote_path")).toString();
    QFile file(path);
    QFileInfo info(path);
    if (!info.isFile() || !file.open(QIODevice::ReadOnly)) {
        QJsonObject err;
        err[QStringLiteral("type")] = QStringLiteral("qd_ftp_error");
        err[QStringLiteral("client_id")] = clientId;
        err[QStringLiteral("transfer_id")] = transferId;
        err[QStringLiteral("message")] = tr("Failed to open remote file");
        sendHost(err);
        return;
    }
    QJsonObject start;
    start[QStringLiteral("type")] = QStringLiteral("qd_ftp_download_start");
    start[QStringLiteral("client_id")] = clientId;
    start[QStringLiteral("transfer_id")] = transferId;
    start[QStringLiteral("remote_path")] = path;
    start[QStringLiteral("filename")] = info.fileName();
    start[QStringLiteral("size")] = static_cast<double>(info.size());
    sendHost(start);

    qint64 sent = 0;
    while (!file.atEnd()) {
        const QByteArray data = file.read(kChunkSize);
        sent += data.size();
        QJsonObject chunk;
        chunk[QStringLiteral("type")] = QStringLiteral("qd_ftp_download_chunk");
        chunk[QStringLiteral("client_id")] = clientId;
        chunk[QStringLiteral("transfer_id")] = transferId;
        chunk[QStringLiteral("data")] = QString::fromLatin1(data.toBase64());
        chunk[QStringLiteral("sent")] = static_cast<double>(sent);
        sendHost(chunk);
    }
    QJsonObject end;
    end[QStringLiteral("type")] = QStringLiteral("qd_ftp_download_end");
    end[QStringLiteral("client_id")] = clientId;
    end[QStringLiteral("transfer_id")] = transferId;
    end[QStringLiteral("remote_path")] = path;
    sendHost(end);
}

void FtpManager::handleClientMessage(const QString& deviceId, const QJsonObject& msg)
{
    const QString type = msg.value(QStringLiteral("type")).toString();
    if (type == QStringLiteral("qd_ftp_list_res")) {
        QVariantList entries;
        const QJsonArray arr = msg.value(QStringLiteral("entries")).toArray();
        for (const auto& v : arr) entries.append(v.toObject().toVariantMap());
        LOG_INFO("[FtpManager] remote directory listed: device={} path={} entries={}",
                 deviceId.toStdString(),
                 msg.value(QStringLiteral("path")).toString().toStdString(),
                 entries.size());
        emit remoteDirectoryListed(deviceId, msg.value(QStringLiteral("path")).toString(), entries);
    } else if (type == QStringLiteral("qd_ftp_download_start")) {
        const QString transferId = msg.value(QStringLiteral("transfer_id")).toString();
        const QString localDir = m_downloadTargetDirs.value(transferId, defaultLocalDirectory());
        const QString filename = msg.value(QStringLiteral("filename")).toString();
        const QString localPath = pathJoin(localDir, filename);
        auto* file = new QFile(localPath, this);
        if (!file->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            file->deleteLater();
            emit errorOccurred(deviceId, QStringLiteral("LOCAL_FILE_OPEN_FAILED"),
                               tr("Failed to create local download file"));
            return;
        }
        DownloadState state;
        state.deviceId = deviceId;
        state.transferId = transferId;
        state.remotePath = msg.value(QStringLiteral("remote_path")).toString();
        state.localPath = localPath;
        state.file = file;
        state.totalBytes = static_cast<qint64>(msg.value(QStringLiteral("size")).toDouble());
        m_downloads.insert(transferId, state);
    } else if (type == QStringLiteral("qd_ftp_download_chunk")) {
        const QString transferId = msg.value(QStringLiteral("transfer_id")).toString();
        auto it = m_downloads.find(transferId);
        if (it == m_downloads.end() || !it->file) return;
        const QByteArray data = QByteArray::fromBase64(msg.value(QStringLiteral("data")).toString().toLatin1());
        it->file->write(data);
        it->receivedBytes += data.size();
        emit transferProgress(deviceId, transferId, QStringLiteral("download"),
                              it->receivedBytes, it->totalBytes,
                              QFileInfo(it->localPath).fileName());
    } else if (type == QStringLiteral("qd_ftp_download_end")) {
        const QString transferId = msg.value(QStringLiteral("transfer_id")).toString();
        auto it = m_downloads.find(transferId);
        if (it == m_downloads.end()) return;
        if (it->file) {
            it->file->close();
            it->file->deleteLater();
        }
        emit transferComplete(deviceId, transferId, QStringLiteral("download"),
                              it->localPath, it->remotePath);
        m_downloads.erase(it);
        m_downloadTargetDirs.remove(transferId);
    } else if (type == QStringLiteral("qd_ftp_upload_done")) {
        const QString transferId = msg.value(QStringLiteral("transfer_id")).toString();
        emit transferComplete(deviceId, transferId, QStringLiteral("upload"),
                              QString(), msg.value(QStringLiteral("remote_path")).toString());
    } else if (type == QStringLiteral("qd_ftp_error")) {
        emit errorOccurred(deviceId, QStringLiteral("FTP_REMOTE_ERROR"),
                           msg.value(QStringLiteral("message")).toString(tr("Remote FTP error")));
    } else if (type == QStringLiteral("qd_ftp_delete_res")) {
        listRemoteDirectory(deviceId, QString());
    }
}

void FtpManager::pumpUploadChunk(const QString& transferId)
{
    auto it = m_uploads.find(transferId);
    if (it == m_uploads.end() || !it->file) return;
    if (it->file->atEnd()) {
        if (it->timer) {
            it->timer->stop();
            it->timer->deleteLater();
        }
        it->file->close();
        it->file->deleteLater();
        QJsonObject end;
        end[QStringLiteral("type")] = QStringLiteral("qd_ftp_upload_end");
        end[QStringLiteral("transfer_id")] = transferId;
        sendClient(it->deviceId, end);
        m_uploads.erase(it);
        return;
    }
    const QByteArray data = it->file->read(kChunkSize);
    it->sentBytes += data.size();
    QJsonObject chunk;
    chunk[QStringLiteral("type")] = QStringLiteral("qd_ftp_upload_chunk");
    chunk[QStringLiteral("transfer_id")] = transferId;
    chunk[QStringLiteral("data")] = QString::fromLatin1(data.toBase64());
    chunk[QStringLiteral("sent")] = static_cast<double>(it->sentBytes);
    sendClient(it->deviceId, chunk);
    emit transferProgress(it->deviceId, transferId, QStringLiteral("upload"),
                          it->sentBytes, it->totalBytes,
                          QFileInfo(it->remotePath).fileName());
}

} // namespace quickdesk
