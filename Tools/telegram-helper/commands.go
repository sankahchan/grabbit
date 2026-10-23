package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gotd/td/telegram/downloader"
	"github.com/gotd/td/tg"
)

type chatJSON struct {
	ID       int64  `json:"id"`
	Title    string `json:"title"`
	Username string `json:"username,omitempty"`
	Kind     string `json:"kind"`
}

type messageJSON struct {
	ID          int    `json:"id"`
	Date        int    `json:"date"`
	Text        string `json:"text,omitempty"`
	MediaKind   string `json:"media_kind,omitempty"`
	FileName    string `json:"file_name,omitempty"`
	MimeType    string `json:"mime_type,omitempty"`
	Size        int64  `json:"size,omitempty"`
	Duration    int    `json:"duration,omitempty"`
	Width       int    `json:"width,omitempty"`
	Height      int    `json:"height,omitempty"`
	CanDownload bool   `json:"can_download"`
}

func chatsData(ctx context.Context, api *tg.Client) ([]byte, error) {
	dialogs, err := fetchDialogs(ctx, api)
	if err != nil {
		return nil, err
	}
	users, chats, channels := dialogEntities(dialogs)
	cache := loadPeerCache()
	cacheEntities(&cache, users, chats, channels)
	savePeerCache(cache)

	out := make([]chatJSON, 0, len(dialogs.GetDialogs()))
	for _, raw := range dialogs.GetDialogs() {
		dialog, ok := raw.(*tg.Dialog)
		if !ok {
			continue
		}
		kind, id, title, username := peerInfo(dialog.Peer, users, chats, channels)
		if title == "" {
			continue
		}
		out = append(out, chatJSON{ID: id, Title: title, Username: username, Kind: kind})
	}
	return json.Marshal(out)
}

func outputChats(ctx context.Context, api *tg.Client) error {
	data, err := chatsData(ctx, api)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(os.Stdout, string(data))
	return err
}

func messagesData(ctx context.Context, api *tg.Client, peer string, limit int) ([]byte, error) {
	inputPeer, _, err := resolveInputPeer(ctx, api, peer)
	if err != nil {
		return nil, err
	}
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	result, err := api.MessagesGetHistory(ctx, &tg.MessagesGetHistoryRequest{
		Peer:  inputPeer,
		Limit: limit,
	})
	if err != nil {
		return nil, fmt.Errorf("get history: %w", err)
	}

	out := make([]messageJSON, 0, limit)
	for _, raw := range messageList(result) {
		msg, ok := raw.(*tg.Message)
		if !ok {
			continue
		}
		info, ok := extractMediaInfo(msg)
		if !ok {
			continue
		}
		info.ID = msg.ID
		info.Date = msg.Date
		info.Text = truncate(msg.Message, 500)
		out = append(out, info)
	}
	return json.Marshal(out)
}

func outputMessages(ctx context.Context, api *tg.Client, peer string, limit int) error {
	data, err := messagesData(ctx, api, peer, limit)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(os.Stdout, string(data))
	return err
}

type downloadOutcome struct {
	size int64
	sha  string
}

func outputDownload(ctx context.Context, api *tg.Client, peer string, messageID int, outPath string, threads int) error {
	if peer == "" || messageID == 0 || outPath == "" {
		return fmt.Errorf("-download requires -peer, -message and -out")
	}
	outcome, err := downloadMessage(ctx, api, peer, messageID, outPath, threads, func(written, total int64) {
		fmt.Printf("PROGRESS\t%d\t%d\n", written, total)
	})
	if err != nil {
		return err
	}
	fmt.Printf("DOWNLOAD_OK\t%s\t%d\t%s\n", outPath, outcome.size, outcome.sha)
	return nil
}

func downloadMessage(ctx context.Context, api *tg.Client, peer string, messageID int, outPath string, threads int, onProgress func(written, total int64)) (downloadOutcome, error) {
	if peer == "" || messageID == 0 || outPath == "" {
		return downloadOutcome{}, fmt.Errorf("download requires peer, message and output path")
	}
	inputPeer, _, err := resolveInputPeer(ctx, api, peer)
	if err != nil {
		return downloadOutcome{}, err
	}
	timing("peer-resolved")
	msg, err := fetchMessageFromPeer(ctx, api, inputPeer, messageID)
	if err != nil {
		return downloadOutcome{}, err
	}
	timing("message-fetched")
	loc, _, size, err := downloadLocation(msg)
	if err != nil {
		return downloadOutcome{}, err
	}
	timing("location-ready")

	if err := os.MkdirAll(filepath.Dir(outPath), 0755); err != nil {
		return downloadOutcome{}, fmt.Errorf("create output directory: %w", err)
	}
	file, err := os.Create(outPath)
	if err != nil {
		return downloadOutcome{}, fmt.Errorf("create output file: %w", err)
	}
	defer file.Close()

	// Telegram serves upload.getFile chunks independently; a few parallel
	// connections substantially improve throughput for video/audio. Small
	// files stay single-threaded to avoid extra round trips.
	if threads < 1 {
		threads = 1
	}
	if threads > 8 {
		threads = 8
	}
	if size > 0 && size < 1<<20 {
		threads = 1
	}
	timing(fmt.Sprintf("threads-%d", threads))
	writer := &progressWriterAt{file: file, total: size, last: time.Now(), onProgress: onProgress}
	_, err = downloader.NewDownloader().
		WithPartSize(512*1024).
		Download(api, loc).
		WithThreads(threads).
		Parallel(ctx, writer)
	if err != nil {
		return downloadOutcome{}, fmt.Errorf("download: %w", err)
	}
	if err := file.Close(); err != nil {
		return downloadOutcome{}, fmt.Errorf("close output file: %w", err)
	}

	file, err = os.Open(outPath)
	if err != nil {
		return downloadOutcome{}, fmt.Errorf("re-open output file: %w", err)
	}
	h := sha256.New()
	if _, err := io.Copy(h, file); err != nil {
		file.Close()
		return downloadOutcome{}, fmt.Errorf("hash output file: %w", err)
	}
	file.Close()
	return downloadOutcome{size: writer.written, sha: hex.EncodeToString(h.Sum(nil))}, nil
}

type progressWriterAt struct {
	file       *os.File
	total      int64
	written    int64
	last       time.Time
	onProgress func(written, total int64)
	mu         sync.Mutex
}

func (p *progressWriterAt) WriteAt(b []byte, off int64) (int, error) {
	if p.total > 0 && off == 0 {
		// Not necessarily the first byte written, but useful for latency
		// measurements when the parallel reader starts at offset zero.
		timing("first-write-at")
	}
	n, err := p.file.WriteAt(b, off)
	p.mu.Lock()
	p.written += int64(n)
	if p.onProgress != nil && (time.Since(p.last) >= 250*time.Millisecond || p.written == p.total) {
		p.last = time.Now()
		p.onProgress(p.written, p.total)
	}
	p.mu.Unlock()
	return n, err
}

func fetchDialogs(ctx context.Context, api *tg.Client) (tg.ModifiedMessagesDialogs, error) {
	result, err := api.MessagesGetDialogs(ctx, &tg.MessagesGetDialogsRequest{
		Limit:      100,
		OffsetPeer: &tg.InputPeerEmpty{},
	})
	if err != nil {
		return nil, fmt.Errorf("get dialogs: %w", err)
	}
	dialogs, ok := result.AsModified()
	if !ok {
		return nil, fmt.Errorf("unexpected dialogs result %T", result)
	}
	return dialogs, nil
}

func dialogEntities(dialogs tg.ModifiedMessagesDialogs) (map[int64]*tg.User, map[int64]*tg.Chat, map[int64]*tg.Channel) {
	users := make(map[int64]*tg.User)
	chats := make(map[int64]*tg.Chat)
	channels := make(map[int64]*tg.Channel)
	for _, raw := range dialogs.GetUsers() {
		if user, ok := raw.(*tg.User); ok {
			users[user.ID] = user
		}
	}
	for _, raw := range dialogs.GetChats() {
		switch chat := raw.(type) {
		case *tg.Chat:
			chats[chat.ID] = chat
		case *tg.Channel:
			channels[chat.ID] = chat
		}
	}
	return users, chats, channels
}

func resolveInputPeer(ctx context.Context, api *tg.Client, raw string) (tg.InputPeerClass, string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, "", fmt.Errorf("peer is empty")
	}
	if raw == "self" || raw == "me" {
		return &tg.InputPeerSelf{}, "Saved Messages", nil
	}

	// The app prefixes dialogs without a username with their peer type
	// (`user:123`, `group:456`, `channel:789`) because numeric ids can
	// collide across Telegram's peer namespaces. Plain usernames and legacy
	// numeric ids still work.
	kindHint := ""
	if kind, rest, ok := strings.Cut(raw, ":"); ok {
		switch kind {
		case "user", "group", "channel":
			kindHint = kind
			raw = rest
		}
	}

	cache := loadPeerCache()
	if !isNumeric(raw) {
		username := strings.TrimPrefix(raw, "@")
		if p, ok := cache.byUsername(username); ok {
			if input, err := p.inputPeer(); err == nil {
				return input, p.Title, nil
			}
		}
		result, err := api.ContactsResolveUsername(ctx, username)
		if err != nil {
			return nil, "", fmt.Errorf("resolve @%s: %w", username, err)
		}
		cacheResolved(&cache, result.Peer, result.Users, result.Chats)
		savePeerCache(cache)
		switch peer := result.Peer.(type) {
		case *tg.PeerUser:
			for _, rawUser := range result.Users {
				if user, ok := rawUser.(*tg.User); ok && user.ID == peer.UserID {
					return user.AsInputPeer(), displayName(user.FirstName, user.LastName), nil
				}
			}
		case *tg.PeerChat:
			for _, rawChat := range result.Chats {
				if chat, ok := rawChat.(*tg.Chat); ok && chat.ID == peer.ChatID {
					return chat.AsInputPeer(), chat.Title, nil
				}
			}
		case *tg.PeerChannel:
			for _, rawChat := range result.Chats {
				if channel, ok := rawChat.(*tg.Channel); ok && channel.ID == peer.ChannelID {
					return channel.AsInputPeer(), channel.Title, nil
				}
			}
		}
		return nil, "", fmt.Errorf("could not build input peer for @%s", username)
	}

	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return nil, "", fmt.Errorf("invalid peer id %q", raw)
	}
	if p, ok := cache.byID(id); ok &&
		(kindHint == "" || p.Kind == kindHint || (kindHint == "group" && p.Kind == "chat")) {
		if input, err := p.inputPeer(); err == nil {
			return input, p.Title, nil
		}
	}
	dialogs, err := fetchDialogs(ctx, api)
	if err != nil {
		return nil, "", err
	}
	users, chats, channels := dialogEntities(dialogs)
	cacheEntities(&cache, users, chats, channels)
	savePeerCache(cache)
	for _, rawDialog := range dialogs.GetDialogs() {
		dialog, ok := rawDialog.(*tg.Dialog)
		if !ok {
			continue
		}
		switch peer := dialog.Peer.(type) {
		case *tg.PeerUser:
			if peer.UserID == id && (kindHint == "" || kindHint == "user") {
				if user := users[id]; user != nil {
					return user.AsInputPeer(), displayName(user.FirstName, user.LastName), nil
				}
			}
		case *tg.PeerChat:
			if peer.ChatID == id && (kindHint == "" || kindHint == "group") {
				if chat := chats[id]; chat != nil {
					return chat.AsInputPeer(), chat.Title, nil
				}
			}
		case *tg.PeerChannel:
			if peer.ChannelID == id && (kindHint == "" || kindHint == "channel") {
				if channel := channels[id]; channel != nil {
					return channel.AsInputPeer(), channel.Title, nil
				}
			}
		}
	}
	if kindHint != "" {
		return nil, "", fmt.Errorf("%s %d was not found in recent dialogs", kindHint, id)
	}
	return nil, "", fmt.Errorf("peer %d was not found in recent dialogs", id)
}

func messageList(result tg.MessagesMessagesClass) []tg.MessageClass {
	switch m := result.(type) {
	case *tg.MessagesMessages:
		return m.Messages
	case *tg.MessagesMessagesSlice:
		return m.Messages
	case *tg.MessagesChannelMessages:
		return m.Messages
	default:
		return nil
	}
}

func fetchMessageFromPeer(ctx context.Context, api *tg.Client, peer tg.InputPeerClass, id int) (*tg.Message, error) {
	result, err := api.MessagesGetHistory(ctx, &tg.MessagesGetHistoryRequest{
		Peer:     peer,
		OffsetID: id + 1,
		Limit:    1,
	})
	if err != nil {
		return nil, fmt.Errorf("fetch message %d: %w", id, err)
	}
	for _, raw := range messageList(result) {
		if msg, ok := raw.(*tg.Message); ok && msg.ID == id {
			return msg, nil
		}
	}
	return nil, fmt.Errorf("message %d was not found", id)
}

func extractMediaInfo(msg *tg.Message) (messageJSON, bool) {
	switch media := msg.Media.(type) {
	case *tg.MessageMediaDocument:
		if media.Document == nil {
			return messageJSON{}, false
		}
		doc, ok := media.Document.AsNotEmpty()
		if !ok {
			return messageJSON{}, false
		}
		info := messageJSON{
			MediaKind:   "document",
			FileName:    documentFileName(doc),
			MimeType:    doc.GetMimeType(),
			Size:        doc.GetSize(),
			CanDownload: true,
		}
		for _, raw := range doc.GetAttributes() {
			switch attr := raw.(type) {
			case *tg.DocumentAttributeFilename:
				if attr.FileName != "" {
					info.FileName = attr.FileName
				}
			case *tg.DocumentAttributeVideo:
				info.MediaKind = "video"
				info.Duration = int(attr.Duration)
				info.Width = attr.W
				info.Height = attr.H
			case *tg.DocumentAttributeAudio:
				info.MediaKind = "audio"
				info.Duration = attr.Duration
			case *tg.DocumentAttributeAnimated:
				info.MediaKind = "gif"
			case *tg.DocumentAttributeSticker:
				info.MediaKind = "sticker"
			}
		}
		if info.FileName == "" {
			info.FileName = fmt.Sprintf("telegram-document-%d", doc.GetID())
		}
		return info, true
	case *tg.MessageMediaPhoto:
		if media.Photo == nil {
			return messageJSON{}, false
		}
		photo, ok := media.Photo.AsNotEmpty()
		if !ok {
			return messageJSON{}, false
		}
		size, ok := largestPhotoSize(photo)
		var sizeBytes int64
		if ok {
			sizeBytes = int64(size.Size)
		}
		return messageJSON{
			MediaKind:   "photo",
			FileName:    fmt.Sprintf("telegram-photo-%d.jpg", photo.ID),
			MimeType:    "image/jpeg",
			Size:        sizeBytes,
			CanDownload: sizeBytes > 0,
		}, true
	default:
		return messageJSON{}, false
	}
}

func downloadLocation(msg *tg.Message) (tg.InputFileLocationClass, string, int64, error) {
	switch media := msg.Media.(type) {
	case *tg.MessageMediaDocument:
		if media.Document == nil {
			return nil, "", 0, fmt.Errorf("document is empty")
		}
		doc, ok := media.Document.AsNotEmpty()
		if !ok {
			return nil, "", 0, fmt.Errorf("document is empty")
		}
		return doc.AsInputDocumentFileLocation(), documentFileName(doc), doc.GetSize(), nil
	case *tg.MessageMediaPhoto:
		if media.Photo == nil {
			return nil, "", 0, fmt.Errorf("photo is empty")
		}
		photo, ok := media.Photo.AsNotEmpty()
		if !ok {
			return nil, "", 0, fmt.Errorf("photo is empty")
		}
		size, ok := largestPhotoSize(photo)
		if !ok {
			return nil, "", 0, fmt.Errorf("photo has no downloadable size")
		}
		loc := &tg.InputPhotoFileLocation{
			ID:            photo.ID,
			AccessHash:    photo.AccessHash,
			FileReference: photo.FileReference,
			ThumbSize:     size.Type,
		}
		return loc, fmt.Sprintf("telegram-photo-%d.jpg", photo.ID), int64(size.Size), nil
	default:
		return nil, "", 0, fmt.Errorf("message %d has unsupported media %T", msg.ID, msg.Media)
	}
}

func documentFileName(doc *tg.Document) string {
	for _, raw := range doc.GetAttributes() {
		if attr, ok := raw.(*tg.DocumentAttributeFilename); ok && attr.FileName != "" {
			return attr.FileName
		}
	}
	return ""
}

type photoSizeChoice struct {
	Type string
	Size int
}

// largestPhotoSize accepts both regular and progressively encoded photos.
// Telegram increasingly uses photoSizeProgressive for uploads; only handling
// photoSize made those photos appear as non-downloadable files.
func largestPhotoSize(photo *tg.Photo) (photoSizeChoice, bool) {
	var best photoSizeChoice
	for _, raw := range photo.Sizes {
		switch size := raw.(type) {
		case *tg.PhotoSize:
			if size.Size > best.Size {
				best = photoSizeChoice{Type: size.Type, Size: size.Size}
			}
		case *tg.PhotoSizeProgressive:
			if len(size.Sizes) == 0 {
				continue
			}
			// Progressive sizes are cumulative JPEG prefixes; the last one
			// is the complete image.
			fullSize := size.Sizes[len(size.Sizes)-1]
			if fullSize > best.Size {
				best = photoSizeChoice{Type: size.Type, Size: fullSize}
			}
		}
	}
	return best, best.Size > 0
}

func isNumeric(s string) bool {
	if s == "" {
		return false
	}
	_, err := strconv.ParseInt(s, 10, 64)
	return err == nil
}

func truncate(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n])
}
