package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/gotd/td/tg"
)

// cachedPeer is the minimum information needed to build an InputPeer again.
// Access hashes are account-scoped secrets: the cache file is written 0600
// next to the Telegram session and never leaves the machine.
type cachedPeer struct {
	ID         int64  `json:"id"`
	AccessHash int64  `json:"access_hash,omitempty"`
	Kind       string `json:"kind"` // user, chat, channel
	Title      string `json:"title,omitempty"`
	Username   string `json:"username,omitempty"`
}

type peerCacheDisk struct {
	UpdatedAt  int64                 `json:"updated_at"`
	ByID       map[int64]cachedPeer  `json:"by_id"`
	ByUsername map[string]cachedPeer `json:"by_username"`
}

var peerCacheMu sync.Mutex

func telegramSupportDir() string {
	base, err := os.UserConfigDir()
	if err != nil || base == "" {
		base = filepath.Join(os.Getenv("HOME"), "Library", "Application Support")
	}
	return filepath.Join(base, "Grabbit", "Telegram")
}

func peerCachePath() string {
	return filepath.Join(telegramSupportDir(), "peers.json")
}

func loadPeerCache() peerCacheDisk {
	cache := peerCacheDisk{
		ByID:       make(map[int64]cachedPeer),
		ByUsername: make(map[string]cachedPeer),
	}
	data, err := os.ReadFile(peerCachePath())
	if err != nil {
		return cache
	}
	if err := json.Unmarshal(data, &cache); err != nil {
		return peerCacheDisk{
			ByID:       make(map[int64]cachedPeer),
			ByUsername: make(map[string]cachedPeer),
		}
	}
	if cache.ByID == nil {
		cache.ByID = make(map[int64]cachedPeer)
	}
	if cache.ByUsername == nil {
		cache.ByUsername = make(map[string]cachedPeer)
	}
	return cache
}

func savePeerCache(cache peerCacheDisk) {
	peerCacheMu.Lock()
	defer peerCacheMu.Unlock()

	if err := os.MkdirAll(telegramSupportDir(), 0700); err != nil {
		return
	}
	data, err := json.MarshalIndent(cache, "", "  ")
	if err != nil {
		return
	}
	path := peerCachePath()
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return
	}
	_ = os.Rename(tmp, path)
}

func (c *peerCacheDisk) remember(p cachedPeer) {
	if p.ID == 0 || p.Kind == "" {
		return
	}
	c.ByID[p.ID] = p
	if p.Username != "" {
		c.ByUsername[strings.ToLower(p.Username)] = p
	}
}

func (c peerCacheDisk) byUsername(username string) (cachedPeer, bool) {
	p, ok := c.ByUsername[strings.ToLower(strings.TrimPrefix(username, "@"))]
	return p, ok
}

func (c peerCacheDisk) byID(id int64) (cachedPeer, bool) {
	p, ok := c.ByID[id]
	return p, ok
}

func (p cachedPeer) inputPeer() (tg.InputPeerClass, error) {
	switch p.Kind {
	case "user":
		if p.AccessHash == 0 {
			return nil, fmt.Errorf("cached user %d has no access hash", p.ID)
		}
		return &tg.InputPeerUser{UserID: p.ID, AccessHash: p.AccessHash}, nil
	case "chat":
		return &tg.InputPeerChat{ChatID: p.ID}, nil
	case "channel":
		if p.AccessHash == 0 {
			return nil, fmt.Errorf("cached channel %d has no access hash", p.ID)
		}
		return &tg.InputPeerChannel{ChannelID: p.ID, AccessHash: p.AccessHash}, nil
	default:
		return nil, fmt.Errorf("cached peer %d has unknown kind %q", p.ID, p.Kind)
	}
}

func cacheEntities(cache *peerCacheDisk, users map[int64]*tg.User, chats map[int64]*tg.Chat, channels map[int64]*tg.Channel) {
	for _, user := range users {
		cache.remember(cachedPeer{
			ID:         user.ID,
			AccessHash: user.AccessHash,
			Kind:       "user",
			Title:      displayName(user.FirstName, user.LastName),
			Username:   user.Username,
		})
	}
	for _, chat := range chats {
		cache.remember(cachedPeer{
			ID:    chat.ID,
			Kind:  "chat",
			Title: chat.Title,
		})
	}
	for _, channel := range channels {
		cache.remember(cachedPeer{
			ID:         channel.ID,
			AccessHash: channel.AccessHash,
			Kind:       "channel",
			Title:      channel.Title,
			Username:   channel.Username,
		})
	}
}

func cacheResolved(cache *peerCacheDisk, peer tg.PeerClass, users []tg.UserClass, chats []tg.ChatClass) {
	switch p := peer.(type) {
	case *tg.PeerUser:
		for _, raw := range users {
			if user, ok := raw.(*tg.User); ok && user.ID == p.UserID {
				cache.remember(cachedPeer{
					ID:         user.ID,
					AccessHash: user.AccessHash,
					Kind:       "user",
					Title:      displayName(user.FirstName, user.LastName),
					Username:   user.Username,
				})
			}
		}
	case *tg.PeerChat:
		for _, raw := range chats {
			if chat, ok := raw.(*tg.Chat); ok && chat.ID == p.ChatID {
				cache.remember(cachedPeer{ID: chat.ID, Kind: "chat", Title: chat.Title})
			}
		}
	case *tg.PeerChannel:
		for _, raw := range chats {
			if channel, ok := raw.(*tg.Channel); ok && channel.ID == p.ChannelID {
				cache.remember(cachedPeer{
					ID:         channel.ID,
					AccessHash: channel.AccessHash,
					Kind:       "channel",
					Title:      channel.Title,
					Username:   channel.Username,
				})
			}
		}
	}
}
